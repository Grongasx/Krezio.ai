import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/analytics/financial_advisors.dart';
import 'package:krezio_ai/ai/analytics/financial_profile.dart';
import 'package:krezio_ai/ai/cesar_text.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';

import '../analytics_test.dart' as a;

/// Imprime os números da análise com o histórico sintético (conferência manual).
void main() {
  test('analytics numbers', () {
    final r = a.repo(goals: [
      FinancialGoal(id: 'g1', title: 'Viagem', targetAmount: 10000, savedAmount: 3000, targetDate: DateTime(2027, 8, 31), createdAt: DateTime(2026, 7, 16)),
      FinancialGoal(id: 'g2', title: 'Carro', targetAmount: 60000, savedAmount: 1000, targetDate: DateTime(2027, 4, 30), createdAt: DateTime(2026, 6, 16)),
    ]);
    final ctx = AnalysisContext(r, now: a.now);
    final p = ctx.profile;
    // ignore: avoid_print
    void out(Object o) => print('AN| $o');
    out('dias=${p.daysOfData} meses=${p.months.length} renda=${p.avgIncome.round()} gasto=${p.avgExpense.round()} sobra=${p.avgNet.round()} sd=${p.sdNet.round()} taxa=${(p.savingsRate * 100).round()}%');
    out('essencial=${p.essentialMonthly.round()} supérfluo=${p.discretionaryMonthly.round()} piso=${ctx.floor} saldo=${ctx.balance.round()}');
    out('fixas=${p.recurringExpenses.map((e) => '${e.title}:${e.amount}@${e.day}').join(', ')}');
    out('diário: média=${Stats.mean(p.dailyVariable).round()} p50=${Stats.median(p.dailyVariable).round()} n=${p.dailyVariable.length}');
    for (final c in p.categories.values) {
      out('cat ${c.category}: média=${c.mean.round()} 30d=${c.last30.round()} cresc=${(c.growth * 100).round()}% tend=${c.trend.round()} freq=${c.perMonth.toStringAsFixed(1)} ticket=${c.avgTicket.round()}');
    }
    final f = ctx.forecast();
    out('forecast: hoje=${f.p50.first.round()} fim(30d) p10/p50/p90=${f.p10[29].round()}/${f.p50[29].round()}/${f.p90[29].round()} '
        '90d=${f.p10.last.round()}/${f.p50.last.round()}/${f.p90.last.round()} chance>piso=${(f.probAbove(ctx.floor) * 100).round()}% menor=${f.lowestMedian.value.round()}@${CesarText.ddmm(f.lowestMedian.day)}');
    for (final price in [300.0, 2000.0, 5000.0, 12000.0, 25000.0]) {
      final adv = PurchaseAdvisor(ctx).evaluate(price: price);
      out('compra ${price.round()}: ${adv.verdict.name} chance=${(adv.chance * 100).round()}% sem=${(adv.chanceWithout * 100).round()}% '
          'quando=${adv.safeFrom == null ? '-' : CesarText.ddmm(adv.safeFrom!)} parcelas=${adv.safeInstallments ?? '-'} atrasoMetas=${adv.goalDelayMonths?.toStringAsFixed(1)}');
    }
    final rep = GoalTracker(ctx).report();
    out('nota=${rep.score} (${rep.label}) orçamentos estourados=${rep.budgetsOver}/${rep.budgetsTotal}');
    for (final s in rep.goals) {
      out('meta ${s.goal.title}: falta=${s.remaining.round()} ritmo=${s.pace.round()} precisa=${s.requiredMonthly?.round()} '
          'prev=${s.projected == null ? '-' : CesarText.ddmm(s.projected!)}/${s.projected?.year} noRitmo=${s.onTrack} chance=${s.chance == null ? '-' : (s.chance! * 100).round()}%');
    }
    final coach = SavingsCoach(ctx);
    for (final c in coach.cuts()) {
      out('corte ${c.title}: ${c.monthly.round()}/mês esforço=${c.effort} — ${c.detail}');
    }
    final t1 = coach.timeToAfford(2000), t2 = coach.timeToAfford(20000), t3 = coach.timeToAfford(20000, extraMonthly: 300);
    out('notebook 2000: ${t1?.months} meses; 20000: ${t2?.months} meses (${((t2?.chance ?? 0) * 100).round()}%); cortando 300: ${t3?.months} meses (${((t3?.chance ?? 0) * 100).round()}%)');
  });
}
