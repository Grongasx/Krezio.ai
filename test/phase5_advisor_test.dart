import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_advisor.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/financial_qa_engine.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

final now = DateTime(2026, 10, 19, 12); // segunda-feira

FinancialTransaction exp(String title, double v, DateTime d,
        {String cat = 'leisure', String pay = 'pix', bool rec = false, TransactionType type = TransactionType.expense}) =>
    FinancialTransaction(
        id: '${title.hashCode}-${d.microsecondsSinceEpoch}-$v',
        title: title,
        amount: v,
        type: type,
        category: cat,
        paymentMethod: pay,
        date: d,
        isRecurrent: rec);

FinancialRepository repoWith(List<FinancialTransaction> txs, {List<FinancialGoal> goals = const [], List<FinancialReminder> reminders = const []}) {
  final r = FinancialRepository();
  r.replaceAllFromCloud(transactions: txs, reminders: reminders, budgets: r.budgets.toList(), goals: goals, categoryOverrides: {});
  return r;
}

/// Três meses e meio de histórico: delivery toda semana, luz todo mês,
/// netflix recorrente, salário.
List<FinancialTransaction> history() {
  final list = <FinancialTransaction>[];
  for (var i = 1; i <= 15; i++) {
    list.add(exp('iFood', 40, now.subtract(Duration(days: i * 7))));
  }
  for (final m in [7, 8, 9, 10]) {
    list.add(exp('Luz', 150.0 + m * 10, DateTime(2026, m, 10), cat: 'housing'));
    list.add(exp('Netflix', 55, DateTime(2026, m, 12), cat: 'leisure', rec: true));
    list.add(exp('Salário', 5000, DateTime(2026, m, 5), cat: 'salary', type: TransactionType.income));
  }
  list.add(exp('Mercado', 300, DateTime(2026, 10, 2), cat: 'supermarket'));
  return list;
}

void main() {
  late LocalFinancialNlpEngine engine;
  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  CesarAdvisor advisor(FinancialRepository r) => CesarAdvisor(repository: r, now: () => now);

  group('5.4', () {
    test('média diária real não se confunde com quanto posso gastar', () {
      final a = advisor(repoWith(history()))..toString();
      final r = a.answer('qual a média que eu gasto por dia?')!;
      expect(r.route, 'advice:daily_average');
      expect(r.text, contains('em 19 dias'));
      expect(a.answer('quanto posso gastar por dia?'), isNull, reason: 'essa é do motor de perguntas');
    });

    test('"quantas vezes pedi iFood?" filtra pelo título', () {
      final repo = repoWith([
        exp('iFood', 60, now.subtract(const Duration(days: 1))),
        exp('iFood', 55.40, now.subtract(const Duration(days: 3))),
        exp('Restaurante', 90, now.subtract(const Duration(days: 2))),
      ]);
      final qa = FinancialQaEngine(repository: repo, now: () => now);
      final r = qa.answer('quantas vezes pedi ifood esse mês?')!;
      expect(r.text, contains('2 vezes'));
      expect(r.text, contains('R\$ 115,40'));
    });
  });

  group('5.5 simulações (nunca registram)', () {
    test('quanto sobra se eu pagar o aluguel (valor do último aluguel)', () {
      final repo = repoWith([...history(), exp('Aluguel', 1400, DateTime(2026, 10, 1), cat: 'housing')]);
      final before = repo.transactions.length;
      final r = advisor(repo).answer('quanto sobra se eu pagar o aluguel?')!;
      expect(r.text, contains('R\$ 1.400,00'));
      expect(r.text, contains('não registrei'));
      expect(repo.transactions.length, before);
    });

    test('se eu cortar o delivery: média mensal', () {
      final r = advisor(repoWith(history())).answer('se eu cortar o ifood, quanto economizo?')!;
      expect(r.route, 'advice:cut');
      expect(r.text, contains('por mês'));
      expect(r.text, contains('por ano'));
    });

    test('se eu guardar 200 por mês, quando bato a meta', () {
      final goal = FinancialGoal(id: 'g', title: 'Viagem', targetAmount: 3000, savedAmount: 1200);
      final r = advisor(repoWith(history(), goals: [goal])).answer('se eu guardar 200 por mês, quando bato a meta?')!;
      expect(r.text, contains('9 meses'));
      expect(r.text, contains('julho de 2027'));
    });
  });

  group('5.5 consultoria', () {
    test('onde posso economizar: categoria que cresceu + fixos', () {
      final txs = [...history(), exp('Bar', 400, now.subtract(const Duration(days: 3)))];
      final r = advisor(repoWith(txs)).answer('onde posso economizar?')!;
      expect(r.route, 'advice:where_to_save');
      expect(r.text, contains('Gastos fixos'));
      expect(r.text, contains('Netflix'));
    });

    test('sem um mês de dados: ainda não tenho dados suficientes', () {
      final r = advisor(repoWith([exp('Bar', 40, now)])).answer('como vou fechar o mês?')!;
      expect(r.text, contains('ainda não tenho dados suficientes'.substring(1)));
    });

    test('projeção do mês e previsão da luz', () {
      final a = advisor(repoWith(history()));
      expect(a.answer('como vou fechar o mês?')!.route, 'advice:projection');
      final luz = a.answer('quanto vem a luz?')!;
      expect(luz.text, contains('R\$ 240,00'), reason: 'média de 260, 250, 240... dos últimos 3 meses');
    });

    test('assinaturas com total anual', () {
      final r = advisor(repoWith(history())).answer('quais assinaturas eu pago?')!;
      expect(r.text, contains('Netflix'));
      expect(r.text, contains('R\$ 660,00 por ano'));
    });

    test('resumo semanal e gasto fora do padrão', () {
      final a = advisor(repoWith([...history(), exp('Bar', 400, now.subtract(const Duration(days: 2)))]));
      expect(a.weeklySummary()!.text, contains('semana passada'));
      final unusual = a.unusualSpending();
      expect(unusual.single.text, contains('Lazer'));
      expect(a.unusualSpending(muted: {'leisure'}), isEmpty);
    });
  });

  group('5.6 aprendizado e preferências (pelo chat)', () {
    test('"desfaz" depois da correção esquece a memória de categoria', () {
      final repo = repoWith([exp('Mercado do Zé', 40, now, cat: 'supermarket')]);
      final a = CesarAssistant(repository: repo, engine: engine, now: () => now);
      a.recordCreated([repo.transactions.single.id]);
      a.beginTurn();
      expect(a.handleCommand('muda a categoria do mercado do zé pra lazer')!.route, 'edited');
      expect(repo.recallCategoryOverride('Mercado do Zé'), 'leisure');
      a.beginTurn();
      expect(a.handleCommand('desfaz')!.route, 'undo');
      expect(repo.recallCategoryOverride('Mercado do Zé'), isNull);
    });

    test('nome do usuário e silenciar aviso', () {
      final repo = repoWith(history());
      final a = CesarAssistant(repository: repo, engine: engine, now: () => now);
      expect(a.handleQuestion('me chama de Gustavo')!.route, 'preference');
      expect(a.userName, 'Gustavo');
      expect(a.handleQuestion('para de me avisar de lazer')!.route, 'preference');
      expect(repo.preference(FinancialRepository.prefMutedUnusual), 'leisure');
    });

    test('notas de abertura: resumo só uma vez por semana', () {
      final repo = repoWith(history());
      final a = CesarAssistant(repository: repo, engine: engine, now: () => now);
      expect(a.openingNotes().where((n) => n.contains('semana passada')), hasLength(1));
      expect(a.openingNotes().where((n) => n.contains('semana passada')), isEmpty);
    });

    test('forma de pagamento mais usada vira sugestão', () {
      final repo = repoWith([for (var i = 0; i < 6; i++) exp('X$i', 10, DateTime.now().subtract(Duration(days: i)), pay: 'debit_card')]);
      expect(repo.mostUsedPaymentMethod, 'debit_card');
      expect(repoWith([exp('X', 10, DateTime.now())]).mostUsedPaymentMethod, isNull);
    });
  });
}
