import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/financial_qa_engine.dart';
import 'package:krezio_ai/ai/goal_command_parser.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  Future<(FinancialRepository, CesarAssistant)> fresh() async {
    SharedPreferences.setMockInitialValues({});
    final repo = FinancialRepository();
    await repo.clearAllData();
    return (repo, CesarAssistant(repository: repo, engine: engine));
  }

  /// Same order as the chat: commands (with rewrite) → questions → new entry.
  AssistantReply? say(FinancialRepository repo, CesarAssistant a, String t) {
    a.beginTurn();
    var text = t;
    final cmd = a.handleCommand(text);
    if (cmd != null && cmd.rewrittenInput == null) return cmd;
    if (cmd != null) text = cmd.rewrittenInput!;
    final q = cmd == null ? a.handleQuestion(text) : null;
    if (q != null) return q;
    final d = engine.parse(text);
    if (LocalFinancialNlpEngine.isRecordable(d)) a.recordCreated(repo.addTransactionFromDraft(d).map((t) => t.id).toList());
    return cmd;
  }

  group('GoalCommandParser (FEAT-012)', () {
    test('aporte, retirada e exclusão, com e sem a palavra "meta"', () {
      final a = GoalCommandParser.parse('coloquei mais 100 na viagem')!;
      expect(a.kind, GoalCommandKind.contribute);
      expect(a.goalTerm, 'viagem');
      expect(a.saidMeta, isFalse);
      expect(a.amount, 100);
      expect(GoalCommandParser.parse('guardei 200 na meta da viagem')!.goalTerm, 'viagem');
      final w = GoalCommandParser.parse('tira 50 da meta')!;
      expect(w.kind, GoalCommandKind.withdraw);
      expect(w.goalTerm, '');
      expect(w.saidMeta, isTrue);
      expect(GoalCommandParser.parse('apaga a meta da viagem')!.kind, GoalCommandKind.delete);
      expect(GoalCommandParser.parse('quanto falta pra minha meta?'), isNull);
    });
  });

  group('Metas pelo chat sem a palavra "meta" (FEAT-012, CONV-026)', () {
    test('"coloquei mais 100 na viagem" aporta na meta existente', () async {
      final (repo, a) = await fresh();
      repo.addGoal(FinancialGoal(id: 'g', title: 'Viagem', targetAmount: 5000));
      final r = say(repo, a, 'coloquei mais 100 na viagem')!;
      expect(r.route, 'goal_contrib');
      expect(repo.goals.single.savedAmount, 100);
      expect(repo.transactions, isEmpty);
    });

    test('sem meta com esse nome é lançamento normal', () async {
      final (repo, a) = await fresh();
      repo.addGoal(FinancialGoal(id: 'g', title: 'Viagem', targetAmount: 5000));
      a.beginTurn();
      expect(a.handleCommand('coloquei 50 no carro'), isNull);
    });

    test('"tira 50 da meta" (única meta) e desfaz', () async {
      final (repo, a) = await fresh();
      repo.addGoal(FinancialGoal(id: 'g', title: 'Viagem', targetAmount: 5000, savedAmount: 300));
      expect(say(repo, a, 'tira 50 da meta')!.route, 'goal_withdraw');
      expect(repo.goals.single.savedAmount, 250);
      say(repo, a, 'desfaz');
      expect(repo.goals.single.savedAmount, 300);
    });

    test('retirada nunca deixa saldo negativo', () async {
      final (repo, a) = await fresh();
      repo.addGoal(FinancialGoal(id: 'g', title: 'Viagem', targetAmount: 5000, savedAmount: 30));
      expect(say(repo, a, 'tirei 100 da viagem')!.text, contains('só havia'));
      expect(repo.goals.single.savedAmount, 0);
    });

    test('"apaga a meta da viagem" confirma antes', () async {
      final (repo, a) = await fresh();
      repo.addGoal(FinancialGoal(id: 'g', title: 'Viagem', targetAmount: 5000));
      expect(say(repo, a, 'apaga a meta da viagem')!.route, 'confirm_delete');
      expect(repo.goals, hasLength(1));
      say(repo, a, 'sim');
      expect(repo.goals, isEmpty);
      say(repo, a, 'desfaz');
      expect(repo.goals, hasLength(1));
    });
  });

  group('"Posso gastar" genérico e dinheiro livre (FEAT-013, CONV-023)', () {
    test('"dá pra gastar 300 nesse fim de semana?" é análise, não transferência', () async {
      final (repo, _) = await fresh();
      final an = AffordabilityAnalyzer(repository: repo);
      for (final p in ['dá pra gastar 300 nesse fim de semana?', 'consigo sair pra jantar gastando 150?', 'da pra eu gastar 200 hoje?']) {
        expect(an.analyze(p), isNotNull, reason: p);
      }
      expect(an.analyze('gastei 300 no fim de semana'), isNull);
    });

    test('"tenho quanto livre até o salário?"', () async {
      final (repo, _) = await fresh();
      final today = DateTime.now();
      repo.addTransaction(FinancialTransaction(
          id: 's', title: 'Salário', amount: 3000, type: TransactionType.income, category: 'salary', paymentMethod: 'pix',
          date: DateTime(today.year, today.month, 1)));
      final qa = FinancialQaEngine(repository: repo);
      final ans = qa.answer('tenho quanto livre até o salário?')!;
      expect(ans.query.kind, QaKind.freeUntilIncome);
      expect(ans.text, contains('R\$ 3.000,00'));
      expect(ans.text, contains('/'));
    });
  });

  group('Lançamentos ligados ao anterior (FEAT-011, FEAT-010)', () {
    test('"mais 20 de gorjeta" herda o crédito e fica ligado ao restaurante', () async {
      final (repo, a) = await fresh();
      say(repo, a, 'gastei 100 no restaurante no crédito à vista');
      expect(repo.transactions, hasLength(1));
      final r = say(repo, a, 'mais 20 de gorjeta')!;
      expect(r.route, 'saved');
      final tip = repo.transactions.firstWhere((t) => t.amount == 20);
      expect(tip.paymentMethod, 'credit_card');
      expect(tip.title, 'Gorjeta');
      expect(tip.category, repo.transactions.firstWhere((t) => t.amount == 100).category);
    });

    test('"e 30 no uber" vira lançamento completo com o mesmo pagamento', () async {
      final (repo, a) = await fresh();
      say(repo, a, 'gastei 50 no mercado no pix');
      a.beginTurn();
      final r = a.handleCommand('e 30 no uber')!;
      expect(r.rewrittenInput, 'gastei 30 no uber no pix');
    });

    test('"repete o último" duplica com os mesmos dados', () async {
      final (repo, a) = await fresh();
      say(repo, a, 'gastei 12 no café no pix');
      expect(say(repo, a, 'repete o último')!.text, contains('R\$ 12,00'));
      expect(repo.transactions.where((t) => t.amount == 12), hasLength(2));
      say(repo, a, 'desfaz');
      expect(repo.transactions, hasLength(1));
    });

    test('nada disso sem lançamento recente', () async {
      final (repo, a) = await fresh();
      a.beginTurn();
      expect(a.handleCommand('mais 20 de gorjeta'), isNull);
      expect(a.handleCommand('repete o último'), isNull);
      expect(repo.transactions, isEmpty);
    });
  });
}
