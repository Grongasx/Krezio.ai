import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/analytics/cash_flow_forecast.dart';
import 'package:krezio_ai/ai/analytics/financial_advisors.dart';
import 'package:krezio_ai/ai/analytics/financial_profile.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

final now = DateTime(2026, 10, 16, 12);

/// Seis meses e meio de uma vida plausível: salário 5000 dia 5, aluguel 1500
/// dia 10, Netflix e Spotify, mercado toda semana, delivery (que cresceu no
/// último mês), Uber e farmácia.
List<FinancialTransaction> history({int seed = 42, bool deliverySpike = true}) {
  final rnd = Random(seed);
  final out = <FinancialTransaction>[];
  var id = 0;
  void add(String title, double v, DateTime d, String cat, {bool income = false, bool rec = false, int? due}) {
    if (d.isAfter(now)) return;
    out.add(FinancialTransaction(
        id: 'h${id++}',
        title: title,
        amount: double.parse(v.toStringAsFixed(2)),
        type: income ? TransactionType.income : TransactionType.expense,
        category: cat,
        paymentMethod: 'pix',
        date: d,
        isRecurrent: rec,
        dueDay: due));
  }

  for (var back = 6; back >= 0; back--) {
    final m = DateTime(now.year, now.month - back);
    add('Salário', 5000, DateTime(m.year, m.month, 5), 'salary', income: true);
    add('Aluguel', 1500, DateTime(m.year, m.month, 10), 'housing', rec: true, due: 10);
    add('Netflix', 55.9, DateTime(m.year, m.month, 12), 'leisure', rec: true, due: 12);
    add('Spotify', 21.9, DateTime(m.year, m.month, 15), 'leisure', rec: true, due: 15);
    for (final d in [3, 10, 17, 24]) {
      add('Mercado', 250 + rnd.nextInt(80) - 40.0, DateTime(m.year, m.month, d), 'supermarket');
    }
    for (var i = 0; i < 8; i++) {
      add('Uber', 22 + rnd.nextInt(12) - 6.0, DateTime(m.year, m.month, 1 + rnd.nextInt(27)), 'transport');
    }
    add('Farmácia', 80, DateTime(m.year, m.month, 20), 'health');
  }
  // Delivery: ~10 pedidos por mês; nos últimos 30 dias, 22.
  for (var day = 200; day >= 0; day--) {
    final d = now.subtract(Duration(days: day));
    final recent = day < 30;
    final chance = recent && deliverySpike ? 0.73 : 0.33;
    if (rnd.nextDouble() < chance) add('iFood', 45 + rnd.nextInt(20) - 10.0, d, 'leisure');
  }
  return out;
}

FinancialRepository repo({List<FinancialTransaction>? txs, List<FinancialGoal> goals = const []}) {
  final r = FinancialRepository();
  r.replaceAllFromCloud(transactions: txs ?? history(), reminders: [], budgets: r.budgets.toList(), goals: goals, categoryOverrides: {});
  return r;
}

void main() {
  group('perfil', () {
    test('acha o salário e as contas fixas sozinho', () {
      final p = FinancialProfile.build(history(), now: now);
      expect(p.hasHistory, isTrue);
      expect(p.months.length, 6);
      final salary = p.recurringIncomes.single;
      expect([salary.amount, salary.day], [5000, 5]);
      final fixed = {for (final r in p.recurringExpenses) r.key: r.amount};
      expect(fixed.keys, containsAll(['aluguel', 'netflix', 'spotify']));
      expect(fixed.keys, isNot(contains('ifood')), reason: 'delivery varia: não é conta fixa');
      expect(p.avgIncome, 5000);
      expect(p.avgNet, inInclusiveRange(1000, 2500));
    });

    test('vê o delivery crescendo contra a média', () {
      final p = FinancialProfile.build(history(), now: now);
      expect(p.categories['leisure']!.growth, greaterThan(0.25));
      expect(FinancialProfile.build(history(deliverySpike: false), now: now).categories['leisure']!.growth, lessThan(0.25));
    });

    test('estatística: inclinação, percentil e normal', () {
      expect(Stats.slope([100, 200, 300, 400]), 100);
      expect(Stats.percentile([1, 2, 3, 4, 5], 0.5), 3);
      expect(Stats.normalCdf(0), closeTo(0.5, 1e-6));
      expect(Stats.normalCdf(1.6449), closeTo(0.95, 1e-3));
    });
  });

  group('projeção de caixa', () {
    test('o salário entra no dia 5 e o aluguel sai no dia 10', () {
      final r = repo();
      final ctx = AnalysisContext(r, now: now);
      final ev = ctx.events(60);
      expect(ev.where((e) => e.label == 'Salário').map((e) => e.day), [DateTime(2026, 11, 5), DateTime(2026, 12, 5)]);
      expect(ev.where((e) => e.label == 'Aluguel').map((e) => e.day.month), [11, 12], reason: 'o de outubro já foi pago');
    });

    test('mesma entrada, mesmo resultado (semente fixa); compra reduz a chance', () {
      final ctx = AnalysisContext(repo(), now: now);
      final a = ctx.forecast(), b = ctx.forecast();
      expect(a.p50, b.p50);
      final floor = ctx.floor;
      final big = ctx.forecast(extra: [CashEvent(DateTime(2026, 10, 16), -ctx.balance, 'compra')]);
      expect(big.probAbove(floor), lessThan(a.probAbove(floor)));
      expect(a.p10.last, lessThanOrEqualTo(a.p50.last));
      expect(a.p50.last, lessThanOrEqualTo(a.p90.last));
    });
  });

  group('posso comprar?', () {
    test('compra pequena: sim, com a chance calculada', () {
      final advice = PurchaseAdvisor(AnalysisContext(repo(), now: now)).evaluate(price: 300, item: 'fone');
      expect(advice.verdict, PurchaseVerdict.yes);
      expect(advice.chance, greaterThanOrEqualTo(0.85));
      expect(advice.lines.first, contains('400 cenários'));
    });

    test('compra maior que o saldo: não agora, e diz quando ou em quantas parcelas', () {
      final ctx = AnalysisContext(repo(), now: now);
      final advice = PurchaseAdvisor(ctx).evaluate(price: ctx.balance + 3000, item: 'moto');
      expect(advice.verdict, PurchaseVerdict.no);
      expect(advice.safeFrom != null || advice.safeInstallments != null, isTrue);
      if (advice.safeFrom != null) expect(advice.safeFrom!.isAfter(now), isTrue);
    });
  });

  group('metas', () {
    test('meta no ritmo: projeção antes do prazo e chance alta', () {
      final goal = FinancialGoal(
          id: 'g', title: 'Viagem', targetAmount: 10000, savedAmount: 3000, targetDate: DateTime(2027, 8, 31), createdAt: DateTime(2026, 7, 16));
      final rep = GoalTracker(AnalysisContext(repo(goals: [goal]), now: now)).report();
      final s = rep.goals.single;
      expect(s.pace, closeTo(1000, 30));
      expect(s.requiredMonthly, closeTo(7000 / 10.5, 30));
      expect(s.onTrack, isTrue);
      expect(s.chance, greaterThan(0.5));
      expect(rep.score, inInclusiveRange(40, 100));
    });

    test('meta atrasada: fora do ritmo', () {
      final goal = FinancialGoal(
          id: 'g', title: 'Carro', targetAmount: 60000, savedAmount: 1000, targetDate: DateTime(2027, 4, 30), createdAt: DateTime(2026, 6, 16));
      final s = GoalTracker(AnalysisContext(repo(goals: [goal]), now: now)).report().goals.single;
      expect(s.onTrack, isFalse);
      expect(s.chance, lessThan(0.2));
    });
  });

  group('o que cortar', () {
    test('acha o delivery e as assinaturas duplicadas, com valores', () {
      final cuts = SavingsCoach(AnalysisContext(repo(), now: now)).cuts();
      final titles = cuts.map((c) => c.title).toList();
      expect(titles, contains('Delivery (iFood)'));
      expect(titles, contains('Assinaturas de streaming'));
      final streaming = cuts.firstWhere((c) => c.title == 'Assinaturas de streaming');
      expect(streaming.monthly, closeTo(21.9, 0.01), reason: 'fica com a Netflix, corta o Spotify');
      expect(cuts.every((c) => c.monthly > 0), isTrue);
    });

    test('notebook de 2000: com o corte chega antes', () {
      final coach = SavingsCoach(AnalysisContext(repo(txs: history().where((t) => t.date.isAfter(DateTime(2026, 4, 1))).toList()), now: now));
      final without = coach.timeToAfford(20000)!;
      final withCut = coach.timeToAfford(20000, extraMonthly: 500)!;
      expect(withCut.months, lessThan(without.months));
      expect(withCut.chance, inInclusiveRange(0.0, 1.0));
      expect(coach.timeToAfford(100)!.months, 0, reason: 'já tem esse dinheiro acima da reserva');
    });
  });
}
