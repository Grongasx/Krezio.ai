import 'dart:math';

import '../../backend/models/financial_goal.dart';
import '../../backend/repositories/financial_repository.dart';
import '../cesar_text.dart';
import 'cash_flow_forecast.dart';
import 'financial_profile.dart';

const _monthNames = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];

String _monthYear(DateTime d) => '${_monthNames[d.month - 1]} de ${d.year}';
String _pct(double p) => '${(p * 100).round()}%';

/// Shared state of one analysis: the profile, the open bills and the balance.
class AnalysisContext {
  final FinancialRepository repository;
  final DateTime now;
  final FinancialProfile profile;

  AnalysisContext(this.repository, {DateTime? now})
      : now = now ?? DateTime.now(),
        profile = FinancialProfile.build(repository.transactions, now: now ?? DateTime.now());

  double get balance => repository.totalBalance;

  /// The minimum the balance should not go below: half a month of what is
  /// essential, at least R$ 200.
  double get floor => max(200.0, (profile.essentialMonthly * 0.5 / 10).round() * 10.0);

  List<CashEvent> events(int days) =>
      CashFlowForecast.knownEvents(profile, transactions: repository.transactions, openBills: repository.openBills, days: days);

  ForecastResult forecast({int days = 90, List<CashEvent> extra = const [], double monthlyCut = 0, bool percentiles = true, int simulations = 400}) =>
      CashFlowForecast.run(
        profile,
        startBalance: balance,
        days: days,
        events: [...events(days), ...extra],
        dailyAdjust: -monthlyCut / 30,
        percentiles: percentiles,
        simulations: simulations,
      );

  /// Chance of staying above the floor (no day-by-day percentiles: faster).
  double chanceAboveFloor({int days = 90, List<CashEvent> extra = const []}) =>
      forecast(days: days, extra: extra, percentiles: false, simulations: 300).probAbove(floor);

  /// Chance of reaching [amount] of savings within [months] months, putting
  /// aside what is usually left plus [extraMonthly] (normal approximation of
  /// the sum of the monthly results).
  double chanceToSave(double amount, int months, {double extraMonthly = 0, double alreadyAvailable = 0}) {
    if (months <= 0) return alreadyAvailable >= amount ? 1 : 0;
    final mu = (profile.avgNet + extraMonthly) * months + alreadyAvailable;
    final sigma = profile.sdNet * sqrt(months.toDouble());
    return Stats.normalCdf((mu - amount) / sigma);
  }
}

// ───────────────────────── purchase ─────────────────────────

enum PurchaseVerdict { yes, caution, no }

class PurchaseAdvice {
  final PurchaseVerdict verdict;
  final double price;
  final int installments;
  final String item;
  final double chance;
  final double chanceWithout;
  final double floor;
  final ({double value, DateTime day}) lowest;
  final DateTime? safeFrom;
  final int? safeInstallments;
  final double? goalDelayMonths;
  final double incomeShare;

  const PurchaseAdvice({
    required this.verdict,
    required this.price,
    required this.installments,
    required this.item,
    required this.chance,
    required this.chanceWithout,
    required this.floor,
    required this.lowest,
    this.safeFrom,
    this.safeInstallments,
    this.goalDelayMonths,
    required this.incomeShare,
  });

  /// The lines of the answer (markdown bullets).
  List<String> get lines => [
        '📉 Simulei 400 cenários dos próximos 90 dias com base nos seus gastos: com a compra, a chance de o saldo ficar acima da sua reserva mínima '
            '(${CesarText.money(floor)}) é de **${_pct(chance)}** (sem a compra: ${_pct(chanceWithout)}).',
        'Ponto mais baixo previsto: ${CesarText.money(lowest.value)} por volta de ${CesarText.ddmm(lowest.day)}.',
        if (incomeShare > 0) 'Isso equivale a ${_pct(incomeShare)} da sua renda mensal${installments > 1 ? ' (cada parcela: ${CesarText.money(price / installments)})' : ''}.',
        if (safeInstallments != null) '💳 Parcelado em **${safeInstallments}x** (se for sem juros), o risco cai bastante.',
        if (safeFrom != null)
          '⏳ Esperando até **${CesarText.ddmm(safeFrom!)}${safeFrom!.year != lowest.day.year ? '/${safeFrom!.year}' : ''}**, a compra fica segura no seu ritmo atual.',
        if (goalDelayMonths != null && goalDelayMonths! >= 0.5) '🎯 Atrasa suas metas em cerca de ${goalDelayMonths!.toStringAsFixed(goalDelayMonths! < 2 ? 1 : 0).replaceAll('.', ',')} ${goalDelayMonths! < 1.5 ? 'mês' : 'meses'}.',
      ];
}

/// "Posso comprar?" answered with the cash-flow simulation: would the
/// balance stay above a safety floor for the next 90 days with the purchase
/// (cash or in installments)? If not, when would it be safe, or in how many
/// installments.
class PurchaseAdvisor {
  final AnalysisContext ctx;
  PurchaseAdvisor(this.ctx);

  List<CashEvent> _purchase(double price, int n, {int startDay = 0}) {
    final today = DateTime(ctx.now.year, ctx.now.month, ctx.now.day);
    if (n <= 1) return [CashEvent(today.add(Duration(days: startDay)), -price, 'compra')];
    return [for (var k = 0; k < n; k++) CashEvent(today.add(Duration(days: startDay + 30 * k)), -price / n, 'parcela ${k + 1}')];
  }

  PurchaseAdvice evaluate({required double price, int installments = 1, String item = 'essa compra'}) {
    final floor = ctx.floor;
    final withIt = ctx.forecast(extra: _purchase(price, installments));
    final chance = withIt.probAbove(floor);
    final chanceWithout = ctx.chanceAboveFloor();
    final verdict = chance >= 0.85 ? PurchaseVerdict.yes : (chance >= 0.5 ? PurchaseVerdict.caution : PurchaseVerdict.no);

    DateTime? safeFrom;
    int? safeN;
    if (verdict != PurchaseVerdict.yes) {
      bool safe({int n = 1, int wait = 0}) =>
          ctx.chanceAboveFloor(days: 30 * wait + 90, extra: _purchase(price, n, startDay: 30 * wait)) >= 0.85;
      // In installments?
      if (installments <= 1) {
        for (final n in const [3, 6, 10, 12]) {
          if (safe(n: n)) {
            safeN = n;
            break;
          }
        }
      }
      // Or waiting: the first month (1..12) when it is safe — binary search,
      // since waiting longer only helps while money is left each month.
      if (safe(n: installments, wait: 12)) {
        var lo = 1, hi = 12;
        while (lo < hi) {
          final mid = (lo + hi) ~/ 2;
          if (safe(n: installments, wait: mid)) {
            hi = mid;
          } else {
            lo = mid + 1;
          }
        }
        safeFrom = DateTime(ctx.now.year, ctx.now.month, ctx.now.day).add(Duration(days: 30 * lo));
      }
    }
    final net = ctx.profile.avgNet;
    final hasGoals = ctx.repository.goals.any((g) => !g.isReached);
    return PurchaseAdvice(
      verdict: verdict,
      price: price,
      installments: installments,
      item: item,
      chance: chance,
      chanceWithout: chanceWithout,
      floor: floor,
      lowest: withIt.lowestMedian,
      safeFrom: safeFrom,
      safeInstallments: safeN,
      goalDelayMonths: hasGoals && net > 0 ? price / net : null,
      incomeShare: ctx.profile.avgIncome > 0 ? price / ctx.profile.avgIncome : 0,
    );
  }
}

// ───────────────────────── goals ─────────────────────────

class GoalStatus {
  final FinancialGoal goal;
  final double remaining;
  final double? monthsLeft;
  final double? requiredMonthly;

  /// What has been put aside per month since the goal was created.
  final double pace;
  final DateTime? projected;
  final bool? onTrack;

  /// Chance of reaching it by the deadline with its share of what is
  /// usually left each month.
  final double? chance;

  const GoalStatus({
    required this.goal,
    required this.remaining,
    this.monthsLeft,
    this.requiredMonthly,
    required this.pace,
    this.projected,
    this.onTrack,
    this.chance,
  });
}

class GoalsReport {
  final List<GoalStatus> goals;
  final double savingsRate;
  final int budgetsOver;
  final int budgetsTotal;
  final int score;
  const GoalsReport({required this.goals, required this.savingsRate, required this.budgetsOver, required this.budgetsTotal, required this.score});

  String get label => score >= 85
      ? 'excelente 🏆'
      : score >= 65
          ? 'bem 👍'
          : score >= 45
              ? 'no caminho, com pontos de atenção ⚠️'
              : 'precisando de ajuste 🔧';
}

/// "Como estou me saindo?": each goal's pace, projected date and chance of
/// reaching the deadline, plus a score (savings rate, goals on track,
/// budgets respected, emergency fund).
class GoalTracker {
  final AnalysisContext ctx;
  GoalTracker(this.ctx);

  static double _months(DateTime from, DateTime to) => to.difference(from).inDays / 30.44;

  GoalsReport report() {
    final p = ctx.profile;
    final active = ctx.repository.goals.where((g) => !g.isReached).toList();
    // What each goal can expect per month: its own pace so far; goals with
    // no pace share what is left of the monthly surplus. All together never
    // more than what is usually left.
    final paces = {for (final g in active) g.id: g.savedAmount / max(1.0, _months(g.createdAt, ctx.now))};
    final surplus = max(0.0, p.avgNet);
    final idle = active.where((g) => paces[g.id]! <= 0).length;
    final paced = paces.values.fold(0.0, (a, v) => a + v);
    final freeForIdle = max(0.0, surplus - paced);
    final expected = {for (final g in active) g.id: paces[g.id]! > 0 ? paces[g.id]! : (idle > 0 ? freeForIdle / idle : 0.0)};
    final expectedTotal = expected.values.fold(0.0, (a, v) => a + v);
    if (expectedTotal > surplus && expectedTotal > 0) {
      expected.updateAll((_, v) => v * surplus / expectedTotal);
    }
    // How much the monthly result varies, relative to it (at least 15%).
    final cv = max(0.15, surplus > 0 ? p.sdNet / surplus : 1.0);
    final statuses = <GoalStatus>[];
    for (final g in active) {
      final pace = paces[g.id]!;
      final left = g.targetDate == null ? null : _months(ctx.now, g.targetDate!);
      final required = left == null ? null : (left > 0 ? g.remaining / left : g.remaining);
      final rate = expected[g.id]!;
      final projected = rate > 0 ? ctx.now.add(Duration(days: (g.remaining / rate * 30.44).round())) : null;
      bool? onTrack;
      double? chance;
      if (left != null) {
        onTrack = left > 0 && rate >= (required ?? double.infinity) * 0.95;
        if (left > 0 && rate > 0) {
          final mu = rate * left;
          final sigma = rate * cv * sqrt(left);
          chance = Stats.normalCdf((mu - g.remaining) / sigma);
        } else {
          chance = 0;
        }
      }
      statuses.add(GoalStatus(
        goal: g,
        remaining: g.remaining,
        monthsLeft: left,
        requiredMonthly: required,
        pace: pace,
        projected: projected,
        onTrack: onTrack,
        chance: chance,
      ));
    }
    final budgets = ctx.repository.budgets.where((b) => b.monthlyLimit > 0).toList();
    final over = budgets.where((b) => b.isOverBudget).length;
    final withDeadline = statuses.where((s) => s.onTrack != null).toList();
    final goalsScore = withDeadline.isEmpty ? 15.0 : 30.0 * withDeadline.where((s) => s.onTrack!).length / withDeadline.length;
    final rateScore = (p.savingsRate / 0.2).clamp(0.0, 1.0) * 40;
    final budgetScore = budgets.isEmpty ? 10.0 : 20.0 * (1 - over / budgets.length);
    final reserve = ctx.repository.goals.where((g) => CesarText.fold(g.title).contains('reserva')).firstOrNull;
    final reserveRatio = reserve != null
        ? reserve.progress
        : (p.essentialMonthly > 0 ? (ctx.balance / (p.essentialMonthly * 3)).clamp(0.0, 1.0) : 0.0);
    final score = (rateScore + goalsScore + budgetScore + reserveRatio * 10).round().clamp(0, 100);
    return GoalsReport(goals: statuses, savingsRate: p.savingsRate, budgetsOver: over, budgetsTotal: budgets.length, score: score);
  }
}

// ───────────────────────── savings coach ─────────────────────────

class CutSuggestion {
  final String category;
  final String title;
  final String detail;
  final double monthly;

  /// 1 easy, 2 medium, 3 hard.
  final int effort;

  const CutSuggestion({required this.category, required this.title, required this.detail, required this.monthly, required this.effort});
}

/// "O que eu devo cortar?", "o que eu poderia fazer para economizar mais?",
/// "se eu cortar isso, em quanto tempo compro um notebook de 2000?". Finds
/// where the money goes beyond the usual (growth against the user's own
/// months, frequency of small purchases, delivery, subscriptions, share of
/// the income against common benchmarks) and turns it into concrete cuts.
class SavingsCoach {
  final AnalysisContext ctx;
  SavingsCoach(this.ctx);

  /// Share of the income above which a category is usually too much.
  static const _benchmarks = {'leisure': 0.10, 'transport': 0.15, 'supermarket': 0.20, 'expense_other': 0.08};

  static const _deliveryApps = {
    r'\bi\s*food\b': 'iFood', r'\brappi\b': 'Rappi', r'\bze\s+delivery\b': 'Zé Delivery', r'\baiqfome\b': 'Aiqfome',
    r'\buber\s+eats\b': 'Uber Eats', r'\b99\s*food\b': '99Food', r'\bjames\b': 'James',
  };

  String _name(String code) => CesarText.categoryName(code, ctx.repository.budgets);

  List<CutSuggestion> cuts() {
    final p = ctx.profile;
    final txs = ctx.repository.transactions;
    final income = p.avgIncome;
    final months = max(1.0, min(6.0, p.daysOfData / 30.44));
    final since = ctx.now.subtract(Duration(days: (months * 30.44).round()));
    final out = <CutSuggestion>[];

    // Delivery apps: frequency × ticket.
    final delivery = txs.where((t) => t.type.name == 'expense' && !t.date.isBefore(since) && FinancialProfile.deliveryTitles.hasMatch(CesarText.fold(t.title))).toList();
    String? deliveryCategory;
    if (delivery.length >= 2) {
      final perMonth = delivery.length / months;
      final total = delivery.fold(0.0, (a, t) => a + t.amount) / months;
      final ticket = total / perMonth;
      final recent = delivery.where((t) => !t.date.isBefore(ctx.now.subtract(const Duration(days: 30))));
      final recentTotal = recent.fold(0.0, (a, t) => a + t.amount);
      if (total >= 60) {
        deliveryCategory = delivery.first.category;
        final spiking = months >= 2 && recentTotal > total * 1.25;
        // Whatever is bigger: back to the usual month, or half the orders.
        final saving = spiking ? max(recentTotal - total, recentTotal / 2) : total / 2;
        // Named by the apps used: "Delivery (iFood)".
        final apps = <String>{
          for (final t in delivery)
            if (_deliveryApps.entries.where((e) => RegExp(e.key).hasMatch(CesarText.fold(t.title))).firstOrNull case final e?) e.value,
        };
        out.add(CutSuggestion(
          category: deliveryCategory,
          title: apps.isEmpty ? 'Delivery' : 'Delivery (${apps.take(2).join(', ')})',
          detail: spiking
              ? 'Nos últimos 30 dias foram ${recent.length} pedidos (${CesarText.money(recentTotal)}), bem acima da sua média de ${CesarText.money(total)} por mês '
                  '(${perMonth.round()} pedidos, ticket de ${CesarText.money(ticket)}). Voltar ao normal — ou pedir metade das vezes — economiza ${CesarText.money(saving)} por mês.'
              : 'Você pede uns ${perMonth.round()} vezes por mês (ticket médio ${CesarText.money(ticket)}, ${CesarText.money(total)}/mês). '
                  'Pedir metade das vezes economiza ${CesarText.money(saving)} por mês.',
          monthly: saving,
          effort: 2,
        ));
      }
    }

    // Streaming and other subscriptions: two or more of the same kind.
    final subs = p.recurringExpenses.where((r) => FinancialProfile.streamingTitles.hasMatch(r.key)).toList()..sort((a, b) => b.amount.compareTo(a.amount));
    if (subs.length >= 2) {
      final keep = subs.first;
      final cut = subs.skip(1).fold(0.0, (a, r) => a + r.amount);
      out.add(CutSuggestion(
        category: keep.category,
        title: 'Assinaturas de streaming',
        detail: 'Você paga ${subs.length}: ${subs.map((r) => '${r.title} (${CesarText.money(r.amount)})').join(', ')}. '
            'Ficar só com ${keep.title} e revezar as outras economiza ${CesarText.money(cut)} por mês.',
        monthly: cut,
        effort: 1,
      ));
    }

    for (final c in p.categories.values) {
      if (c.essential && c.category != 'supermarket' && c.category != 'transport') continue;
      final name = _name(c.category);
      // Growing against the user's own months — without the delivery
      // already counted above (it was the same money twice).
      var last30 = c.last30, mean = c.mean;
      if (c.category == deliveryCategory) {
        final dRecent = delivery.where((t) => !t.date.isBefore(ctx.now.subtract(const Duration(days: 30)))).fold(0.0, (a, t) => a + t.amount);
        last30 -= dRecent;
        mean -= delivery.fold(0.0, (a, t) => a + t.amount) / months;
      }
      final growth = mean > 0 ? last30 / mean - 1 : 0.0;
      if (c.monthly.length >= 2 && growth >= 0.25 && last30 - mean >= 50) {
        out.add(CutSuggestion(
          category: c.category,
          title: name,
          detail: 'Nos últimos 30 dias foram ${CesarText.money(last30)}, ${_pct(growth)} acima da sua média (${CesarText.money(mean)})'
              '${c.category == deliveryCategory ? ', fora o delivery' : ''}. Voltar à média economiza ${CesarText.money(last30 - mean)} por mês.',
          monthly: last30 - mean,
          effort: 1,
        ));
        continue;
      }
      if (c.trend > 30 && c.monthly.length >= 3) {
        out.add(CutSuggestion(
          category: c.category,
          title: name,
          detail: 'Vem subindo ${CesarText.money(c.trend)} por mês. Segurar no valor do mês mais baixo economiza ${CesarText.money(c.mean - c.monthly.reduce(min))} por mês.',
          monthly: c.mean - c.monthly.reduce(min),
          effort: 2,
        ));
        continue;
      }
      // Above a common share of the income.
      final bench = _benchmarks[c.category];
      if (bench != null && income > 0 && c.mean / income > bench + 0.02) {
        final excess = c.mean - bench * income;
        out.add(CutSuggestion(
          category: c.category,
          title: name,
          detail: 'Leva ${_pct(c.mean / income)} da sua renda (o comum é até ${_pct(bench)}). '
              '${c.category == 'supermarket' ? 'Lista de compras, marcas próprias e atacarejo ajudam: ' : 'Trazer para ${_pct(bench)} '}economiza ${CesarText.money(excess)} por mês.',
          monthly: excess,
          effort: c.category == 'supermarket' ? 3 : 2,
        ));
        continue;
      }
      // Many small purchases.
      if (!c.essential && c.perMonth >= 10 && c.avgTicket < 40 && c.mean >= 150) {
        out.add(CutSuggestion(
          category: c.category,
          title: name,
          detail: 'São ~${c.perMonth.round()} compras pequenas por mês (média ${CesarText.money(c.avgTicket)}) — elas somam ${CesarText.money(c.mean)}. '
              'Cortar um terço delas economiza ${CesarText.money(c.mean / 3)} por mês.',
          monthly: c.mean / 3,
          effort: 2,
        ));
      }
    }

    // One per category, the biggest; easiest first among similar values.
    final best = <String, CutSuggestion>{};
    for (final s in out) {
      final cur = best[s.title];
      if (cur == null || s.monthly > cur.monthly) best[s.title] = s;
    }
    final list = best.values.where((s) => s.monthly >= 20).toList()
      ..sort((a, b) => (b.monthly / (1 + 0.35 * (b.effort - 1))).compareTo(a.monthly / (1 + 0.35 * (a.effort - 1))));
    if (list.isEmpty && p.discretionaryMonthly >= 100) {
      list.add(CutSuggestion(
        category: 'leisure',
        title: 'Gastos não essenciais',
        detail: 'Seus gastos estão dentro do seu padrão. Reduzir 10% do que não é essencial (${CesarText.money(p.discretionaryMonthly)}/mês) '
            'economiza ${CesarText.money(p.discretionaryMonthly * 0.1)} por mês.',
        monthly: p.discretionaryMonthly * 0.1,
        effort: 1,
      ));
    }
    return list.take(5).toList();
  }

  /// Months to have [price] available: what is above the safety floor now,
  /// plus what is usually left each month (+ [extraMonthly]). Null when
  /// nothing is left at the end of the month.
  ({int months, double perMonth, double chance})? timeToAfford(double price, {double extraMonthly = 0}) {
    final available = max(0.0, ctx.balance - ctx.floor);
    final perMonth = ctx.profile.avgNet + extraMonthly;
    if (available >= price) return (months: 0, perMonth: perMonth, chance: 1.0);
    if (perMonth <= 0) return null;
    // The first month with at least 80% chance of having it (the plain
    // division is only a coin flip when the months vary).
    var months = ((price - available) / perMonth).ceil();
    var chance = ctx.chanceToSave(price, months, extraMonthly: extraMonthly, alreadyAvailable: available);
    for (var extra = 0; extra < 12 && chance < 0.8; extra++) {
      months++;
      chance = ctx.chanceToSave(price, months, extraMonthly: extraMonthly, alreadyAvailable: available);
    }
    return (months: months, perMonth: perMonth, chance: chance);
  }

  /// Months each active goal gains with [extraMonthly] more saved per month.
  List<({FinancialGoal goal, double before, double after})> goalImpact(double extraMonthly) {
    final net = ctx.profile.avgNet;
    if (extraMonthly <= 0) return const [];
    final active = ctx.repository.goals.where((g) => !g.isReached).toList();
    if (active.isEmpty) return const [];
    final share = 1 / active.length;
    return [
      for (final g in active)
        (
          goal: g,
          before: net > 0 ? g.remaining / (net * share) : double.infinity,
          after: g.remaining / (max(0.0, net) * share + extraMonthly * share),
        ),
    ];
  }

  String monthsLabel(int m) => m == 0 ? 'já dá' : (m == 1 ? '1 mês' : '$m meses');
  String whenLabel(int m) => _monthYear(DateTime(ctx.now.year, ctx.now.month + m));
}
