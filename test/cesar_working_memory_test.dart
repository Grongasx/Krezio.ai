import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/cesar_text.dart';
import 'package:krezio_ai/ai/cesar_working_memory.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestHarness {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;

  TestHarness(this.engine, this.repo)
      : assistant = CesarAssistant(repository: repo, engine: engine);

  AssistantReply? send(String input) {
    var text = input.trim();
    engine.setCustomCategories(repo.customCategoryNames);
    assistant.beginTurn();

    final cmd = assistant.handleCommand(text);
    if (cmd != null && cmd.rewrittenInput == null) return cmd;
    if (cmd != null && cmd.rewrittenInput != null) text = cmd.rewrittenInput!;

    final q = assistant.handleQuestion(text);
    if (q != null) return q;

    final draft = engine.parse(text);
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      final ids = repo.addTransactionFromDraft(draft).map((t) => t.id).toList();
      assistant.recordCreated(ids);
      return AssistantReply('Registrado: ${draft.description}', route: 'recorded');
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(
      await File('models/on_device/krezio_nlp_model.json').readAsString(),
    );
  });

  Future<TestHarness> fresh() async {
    SharedPreferences.setMockInitialValues({});
    final repo = FinancialRepository();
    await repo.initialize();
    return TestHarness(engine, repo);
  }

  group('CesarWorkingMemory — Testes Unitários de Memória & Portões de Contexto', () {
    test('Ciclo de vida do frame e decaimento por TTL', () {
      final mem = CesarWorkingMemory();
      expect(mem.activeFrame, isNull);

      mem.updateFrame(
        personName: 'Carlos',
        topic: WorkingMemoryTopic.debt,
        ttl: 2,
      );
      expect(mem.lastPersonName, 'Carlos');
      expect(mem.activeFrame?.ttl, 2);

      // Turno 1: decai para 1
      mem.beginTurn();
      expect(mem.lastPersonName, 'Carlos');
      expect(mem.activeFrame?.ttl, 1);

      // Turno 2: expira e evicta
      mem.beginTurn();
      expect(mem.activeFrame, isNull);
      expect(mem.lastPersonName, isNull);
    });

    test('Hard Reset Gate purga o contexto imediatamente em cancelamentos', () {
      final mem = CesarWorkingMemory();
      mem.updateFrame(
        personName: 'Roberto',
        goalTitle: 'carro',
        topic: WorkingMemoryTopic.debt,
      );
      expect(mem.lastPersonName, 'Roberto');

      expect(mem.checkAndApplyDisruption('cancela tudo'), isTrue);
      expect(mem.activeFrame, isNull);

      mem.updateFrame(personName: 'Mariana', topic: WorkingMemoryTopic.debt);
      expect(mem.checkAndApplyDisruption('deixa pra la'), isTrue);
      expect(mem.activeFrame, isNull);

      mem.updateFrame(personName: 'Lucas', topic: WorkingMemoryTopic.debt);
      expect(mem.checkAndApplyDisruption('mudei de ideia'), isTrue);
      expect(mem.activeFrame, isNull);
    });

    test('Resolução anafórica de pessoa ("ele me pagou 50", "ele quitou", "quanto ele deve")', () {
      final mem = CesarWorkingMemory();
      mem.updateFrame(personName: 'João', topic: WorkingMemoryTopic.debt);

      expect(mem.resolveAnaphora('ele me pagou 50'), 'o João me pagou 50');
      expect(mem.resolveAnaphora('ele me pagou tudo'), 'o João me pagou tudo');
      expect(mem.resolveAnaphora('ele quitou a dívida'), 'o João quitou a dívida');
      expect(mem.resolveAnaphora('quanto ele ainda deve?'), 'quanto o João ainda deve?');
    });

    test('Resolução anafórica de meta ("guardei 200 nela", "quanto falta nela?")', () {
      final mem = CesarWorkingMemory();
      mem.updateFrame(goalTitle: 'viagem', topic: WorkingMemoryTopic.goal);

      expect(mem.resolveAnaphora('guardei 200 nela'), 'guardei 200 na meta viagem');
      expect(mem.resolveAnaphora('guardei mais 150 nessa meta'), 'guardei 150 na meta viagem');
      expect(mem.resolveAnaphora('quanto falta nela?'), 'quanto falta para a meta viagem');
    });

    test('Resolução anafórica de divisão de conta sem valor repetido', () {
      final mem = CesarWorkingMemory();
      mem.updateFrame(
        transactionTitle: 'Jantar',
        transactionAmount: 240.0,
        topic: WorkingMemoryTopic.expense,
      );

      final resolved = mem.resolveAnaphora('divide em 3 com o Pedro e a Ana');
      expect(resolved, contains('o Jantar deu 240.00'));
      expect(resolved, contains('divide em 3 com o Pedro e a Ana'));
    });
  });

  group('Invariância ML & Testes End-to-End Multi-Turno', () {
    test('Fluxo completo de cobrança com pronomes e anáfora contínua', () async {
      final h = await fresh();
      final today = DateTime.now();

      // Setup de cobrança
      h.repo.addReminder(FinancialReminder(
        id: 'rem-joao',
        title: 'Empréstimo João',
        amount: 200.0,
        targetDate: today.add(const Duration(days: 5)),
        type: ReminderType.loanReceivable,
        personName: 'João',
      ));

      // Turno 1: Usuário pergunta quem está devendo
      final r1 = h.send('quem está me devendo e quanto falta receber');
      expect(r1, isNotNull);
      expect(r1!.route, 'planner:charge');
      expect(r1.text, contains('João'));
      expect(r1.text, contains('350'));

      // Verifica se a working memory capturou João
      expect(h.assistant.workingMemory.lastPersonName, equals('João'));

      // Turno 2: Pergunta anafórica sem repetir o nome ("quanto ele ainda deve?")
      final r2 = h.send('quanto ele ainda deve?');
      expect(r2, isNotNull);
      expect(r2!.route, 'planner:charge');
      expect(r2.text, contains('João'));
      expect(r2.text, contains('350'));

      // Turno 3: Pagamento parcial anafórico ("ele me pagou 50")
      final r3 = h.send('ele me pagou 50');
      expect(r3, isNotNull);
      expect(r3!.route, 'debt_payment_resolved');
      expect(r3.text, contains('João'));
      expect(r3.text, contains('50'));

      // Turno 4: Valida saldo atualizado ("quanto ele ainda deve?")
      final r4 = h.send('quanto ele ainda deve?');
      expect(r4, isNotNull);
      expect(r4!.text, contains('300'));

      // Turno 5: Quitação total anafórica ("ele me pagou tudo")
      final r5 = h.send('ele me pagou tudo');
      expect(r5, isNotNull);
      expect(r5!.route, 'debt_payment_resolved');
      expect(r5.text, contains('quitou'));

      // Turno 6: Conferência final
      final r6 = h.send('quanto ele ainda deve?');
      expect(r6, isNotNull);
      expect(r6!.text, contains('não tem nenhuma dívida'));
    });

    test('Divisão de conta pós-lançamento de despesa sem duplicação', () async {
      final h = await fresh();

      // Turno 1: Usuário lança um almoço de 180 reais
      final r1 = h.send('almoço de 180 reais no restaurante no pix');
      expect(r1, isNotNull);
      expect(h.repo.transactions.where((t) => !t.id.startsWith('init-')).length, 1);
      expect(h.repo.transactions.firstWhere((t) => !t.id.startsWith('init-')).amount, 180.0);

      // Turno 2: Divide o gasto recém-lançado sem repetir o valor
      final r2 = h.send('divide em 3 com o Carlos e a Bia');
      expect(r2, isNotNull);
      expect(r2!.route, 'split');
      expect(r2.text, contains('180'));
      expect(r2.text, contains('60'));

      // Validação arquitetural: o almoço original de 180 foi substituído pela minha parte (60)
      // e os recebíveis (120 no total) foram agendados!
      final myExpenses = h.repo.transactions.where((t) => t.type == TransactionType.expense && !t.id.startsWith('init-')).toList();
      expect(myExpenses.length, 1);
      expect(myExpenses.first.amount, 60.0);

      final reminders = h.repo.reminders.where((r) => !r.id.startsWith('rem-seed-')).toList();
      expect(reminders.length, 2);
      expect(reminders.any((r) => r.personName == 'Carlos' && r.amount == 60.0), isTrue);
      expect(reminders.any((r) => r.personName == 'Bia' && r.amount == 60.0), isTrue);
    });

    test('Contribuição anafórica para meta financeira ("guardei mais 250 nela")', () async {
      final h = await fresh();

      // Turno 1: Criação de meta
      h.repo.addGoal(FinancialGoal(
        id: 'goal-viagem',
        title: 'Viagem',
        targetAmount: 3000.0,
        savedAmount: 500.0,
      ));

      // Consulta a meta
      final r1 = h.send('quanto tenho na meta da viagem?');
      expect(r1, isNotNull);
      expect(r1!.text, contains('500'));

      // Turno 2: Contribui usando anáfora
      final r2 = h.send('guardei mais 250 nela');
      expect(r2, isNotNull);
      expect(r2!.route, 'goal_contrib');
      expect(r2.text, contains('750'));

      final updatedGoal = h.repo.goals.firstWhere((g) => g.id == 'goal-viagem');
      expect(updatedGoal.savedAmount, 750.0);
    });

    test('Invariância: Turnos autônomos produzem resposta idêntica independente de histórico ruidoso prévio', () async {
      final hClean = await fresh();
      final hNoisy = await fresh();

      // Noisy harness tem histórico prévio de pizza, conversa e metas
      hNoisy.send('pizza de 70 reais no debito');
      hNoisy.send('como esta o meu saldo?');
      hNoisy.send('valeu cesar');

      // Executa o mesmo comando financeiro puro em ambos
      final rClean = hClean.send('comprei remedio de 320 reais no cartao em 4x');
      final rNoisy = hNoisy.send('comprei remedio de 320 reais no cartao em 4x');

      expect(rClean, isNotNull);
      expect(rNoisy, isNotNull);
      expect(rClean!.route, equals(rNoisy!.route));

      final txClean = hClean.repo.transactions.firstWhere((t) => CesarText.simplify(t.title).contains('remedio'));
      final txNoisy = hNoisy.repo.transactions.firstWhere((t) => CesarText.simplify(t.title).contains('remedio'));

      expect(txClean.amount, equals(txNoisy.amount));
      expect(txClean.installments, equals(txNoisy.installments));
      expect(txClean.paymentMethod, equals(txNoisy.paymentMethod));
    });
  });
}
