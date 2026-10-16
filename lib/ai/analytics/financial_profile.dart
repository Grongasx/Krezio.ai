import 'dart:math';

import '../../backend/models/financial_transaction.dart';
import '../cesar_text.dart';

/// Basic statistics, shared by the analytics.
class Stats {
  Stats._();

  static double mean(List<double> xs) => xs.isEmpty ? 0 : xs.reduce((a, b) => a + b) / xs.length;

  static double median(List<double> xs) {
    if (xs.isEmpty) return 0;
    final s = [...xs]..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
  }

  /// Sample standard deviation.
  static double sd(List<double> xs) {
    if (xs.length < 2) return 0;
    final m = mean(xs);
    return sqrt(xs.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / (xs.length - 1));
  }

  /// [p] in 0..1, linear interpolation.
  static double percentile(List<double> xs, double p) {
    if (xs.isEmpty) return 0;
    final s = [...xs]..sort();
    final pos = (s.length - 1) * p;
    final lo = pos.floor(), hi = pos.ceil();
    return s[lo] + (s[hi] - s[lo]) * (pos - lo);
  }

  /// Least-squares slope of [ys] against 0, 1, 2… (change per step).
  static double slope(List<double> ys) {
    final n = ys.length;
    if (n < 2) return 0;
    final mx = (n - 1) / 2, my = mean(ys);
    var num = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      num += (i - mx) * (ys[i] - my);
      den += (i - mx) * (i - mx);
    }
    return den == 0 ? 0 : num / den;
  }

  /// Standard normal CDF (Abramowitz–Stegun 7.1.26, error < 1.5e-7).
  static double normalCdf(double z) {
    final t = 1 / (1 + 0.3275911 * z.abs() / sqrt2);
    final y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-z * z / 2);
    return z >= 0 ? (1 + y) / 2 : (1 - y) / 2;
  }
}

/// One expense category, month by month.
class CategoryStats {
  final String category;

  /// Totals of the full months, oldest first (the current month, pro-rated,
  /// when there is no full month yet).
  final List<double> monthly;
  final double mean;
  final double median;
  final double sd;

  /// Change per month (least squares), R$.
  final double trend;

  /// Spent in the last 30 days.
  final double last30;

  /// Purchases per month and their average value.
  final double perMonth;
  final double avgTicket;
  final bool essential;

  const CategoryStats({
    required this.category,
    required this.monthly,
    required this.mean,
    required this.median,
    required this.sd,
    required this.trend,
    required this.last30,
    required this.perMonth,
    required this.avgTicket,
    required this.essential,
  });

  /// How much the last 30 days are above the usual month (0.25 = 25% more).
  double get growth => mean > 0 ? last30 / mean - 1 : 0;
}

/// A bill or an income that comes back every month.
class RecurringItem {
  final String title;
  final String key;
  final double amount;
  final int day;
  final bool income;
  final String category;

  /// Said as recurring by the user (true) or found in the history (false).
  final bool declared;

  const RecurringItem({
    required this.title,
    required this.key,
    required this.amount,
    required this.day,
    required this.income,
    required this.category,
    required this.declared,
  });
}

/// Everything the forecasts and the advice are computed from: monthly
/// series, per-category statistics, the bills and incomes that repeat, and
/// the day-by-day variable spending. Pure Dart; [now] is injected.
class FinancialProfile {
  final DateTime now;
  final int daysOfData;

  /// Full months used (up to 6), oldest first.
  final List<({DateTime month, double income, double expense})> months;
  final Map<String, CategoryStats> categories;
  final List<RecurringItem> recurringExpenses;
  final List<RecurringItem> recurringIncomes;

  /// Variable (non-recurring) spending of each of the last days (≤ 90),
  /// with outliers capped at the 95th percentile — what a day usually costs.
  final List<double> dailyVariable;

  /// The current month so far: income, and expenses pro-rated to a full month.
  final double _currentIncome;
  final double _currentExpenseProrated;

  const FinancialProfile._({
    required this.now,
    required this.daysOfData,
    required this.months,
    required this.categories,
    required this.recurringExpenses,
    required this.recurringIncomes,
    required this.dailyVariable,
    double currentIncome = 0,
    double currentExpenseProrated = 0,
  })  : _currentIncome = currentIncome,
        _currentExpenseProrated = currentExpenseProrated;

  static const essentialCategories = {'housing', 'health', 'education', 'supermarket', 'bills', 'transport'};
  static final deliveryTitles = RegExp(r'\b(?:ifood|i\s*food|rappi|ze\s+delivery|aiqfome|delivery|uber\s+eats|james|99\s*food)\b');
  static final streamingTitles = RegExp(r'\b(?:netflix|spotify|prime|amazon\s+prime|disney|hbo|max|globoplay|deezer|youtube|apple\s+tv|paramount|star\+?|crunchyroll|twitch)\b');

  bool get hasHistory => daysOfData >= 30;

  double get avgIncome => months.isEmpty ? _currentIncome : Stats.mean(months.map((m) => m.income).toList());
  double get avgExpense => months.isEmpty ? _currentExpenseProrated : Stats.mean(months.map((m) => m.expense).toList());

  /// What is usually left at the end of a month.
  double get avgNet => avgIncome - avgExpense;

  /// How much that varies month to month (an estimate with < 3 months).
  double get sdNet {
    final nets = months.map((m) => m.income - m.expense).toList();
    if (nets.length >= 3) return max(Stats.sd(nets), 50);
    return max(avgNet.abs() * 0.25, 100);
  }

  double get savingsRate => avgIncome > 0 ? avgNet / avgIncome : 0;

  double get recurringExpenseMonthly => recurringExpenses.fold(0.0, (a, r) => a + r.amount);

  /// What a month costs no matter what: the usual spending in essential
  /// categories (their bills included) plus the fixed bills of the others.
  double get essentialMonthly {
    var essential = 0.0;
    for (final c in categories.values) {
      if (c.essential) essential += c.mean;
    }
    return essential + recurringExpenses.where((r) => !essentialCategories.contains(r.category)).fold(0.0, (a, r) => a + r.amount);
  }

  double get discretionaryMonthly =>
      categories.values.where((c) => !c.essential).fold(0.0, (a, c) => a + c.mean);

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  factory FinancialProfile.build(Iterable<FinancialTransaction> all, {required DateTime now}) {
    final today = _day(now);
    final txs = all.where((t) => !t.isInternalTransfer && !_day(t.date).isAfter(today)).toList();
    if (txs.isEmpty) {
      return FinancialProfile._(
          now: now, daysOfData: 0, months: const [], categories: const {}, recurringExpenses: const [], recurringIncomes: const [], dailyVariable: const []);
    }
    final first = txs.map((t) => _day(t.date)).reduce((a, b) => a.isBefore(b) ? a : b);
    final daysOfData = today.difference(first).inDays + 1;

    // Full months: data must start by the 8th of that month.
    final fullMonths = <DateTime>[];
    for (var back = 6; back >= 1; back--) {
      final m = DateTime(today.year, today.month - back);
      if (!first.isAfter(DateTime(m.year, m.month, 8))) fullMonths.add(m);
    }
    bool inMonth(FinancialTransaction t, DateTime m) => t.date.year == m.year && t.date.month == m.month;

    final months = [
      for (final m in fullMonths)
        (
          month: m,
          income: txs.where((t) => inMonth(t, m) && t.type == TransactionType.income).fold(0.0, (a, t) => a + t.amount),
          expense: txs.where((t) => inMonth(t, m) && _isOutflow(t)).fold(0.0, (a, t) => a + t.amount),
        ),
    ];

    // Recurring: declared bills, and titles that come back every month with
    // about the same value.
    final recurringExpenses = <RecurringItem>[];
    final recurringIncomes = <RecurringItem>[];
    final groups = <String, List<FinancialTransaction>>{};
    for (final t in txs.where((t) => t.date.isAfter(today.subtract(const Duration(days: 190))))) {
      groups.putIfAbsent('${t.type == TransactionType.income ? 'in' : 'out'}:${CesarText.fold(t.title)}', () => []).add(t);
    }
    for (final e in groups.entries) {
      final list = e.value..sort((a, b) => a.date.compareTo(b.date));
      final income = e.key.startsWith('in:');
      final last = list.last;
      final distinctMonths = list.map((t) => t.date.year * 12 + t.date.month).toSet().length;
      final perMonth = list.length / distinctMonths;
      final amounts = list.map((t) => t.amount).toList();
      final med = Stats.median(amounts);
      final steady = amounts.every((a) => (a - med).abs() <= med * 0.15);
      final declared = !income && list.any((t) => t.isRecurrent);
      final salary = income && last.category == 'salary';
      final inferred = distinctMonths >= 2 && perMonth <= 1.5 && steady;
      if (!(declared || salary || inferred)) continue;
      if (!income && last.type != TransactionType.expense) continue;
      final day = last.dueDay ?? Stats.median(list.map((t) => t.date.day.toDouble()).toList()).round();
      final item = RecurringItem(
        title: last.title,
        key: CesarText.fold(last.title),
        amount: declared ? last.amount : med,
        day: day.clamp(1, 31),
        income: income,
        category: last.category,
        declared: declared || salary,
      );
      (income ? recurringIncomes : recurringExpenses).add(item);
    }
    final recurringKeys = recurringExpenses.map((r) => r.key).toSet();

    // Per category.
    final daysInMonth = DateTime(today.year, today.month + 1, 0).day;
    final categories = <String, CategoryStats>{};
    final cats = txs.where((t) => t.type == TransactionType.expense).map((t) => t.category).toSet();
    for (final c in cats) {
      final ofCat = txs.where((t) => t.type == TransactionType.expense && t.category == c).toList();
      List<double> monthly;
      double count;
      if (fullMonths.isNotEmpty) {
        monthly = [for (final m in fullMonths) ofCat.where((t) => inMonth(t, m)).fold(0.0, (a, t) => a + t.amount)];
        count = ofCat.where((t) => fullMonths.any((m) => inMonth(t, m))).length / fullMonths.length;
      } else {
        // Only the current month: its variable part pro-rated to a full month.
        final cur = ofCat.where((t) => inMonth(t, today));
        final fixed = cur.where((t) => recurringKeys.contains(CesarText.fold(t.title))).fold(0.0, (a, t) => a + t.amount);
        final variable = cur.where((t) => !recurringKeys.contains(CesarText.fold(t.title))).fold(0.0, (a, t) => a + t.amount);
        monthly = [fixed + variable * daysInMonth / today.day];
        count = cur.length * daysInMonth / today.day;
      }
      final last30 = ofCat.where((t) => !_day(t.date).isBefore(today.subtract(const Duration(days: 29)))).fold(0.0, (a, t) => a + t.amount);
      final total = ofCat.fold(0.0, (a, t) => a + t.amount);
      categories[c] = CategoryStats(
        category: c,
        monthly: monthly,
        mean: Stats.mean(monthly),
        median: Stats.median(monthly),
        sd: Stats.sd(monthly),
        trend: monthly.length >= 3 ? Stats.slope(monthly) : 0,
        last30: last30,
        perMonth: count,
        avgTicket: ofCat.isEmpty ? 0 : total / ofCat.length,
        essential: essentialCategories.contains(c),
      );
    }

    // Day by day variable spending (non-recurring outflows).
    final window = min(90, daysOfData);
    final byDay = <DateTime, double>{};
    for (final t in txs.where((t) => _isOutflow(t) && !recurringKeys.contains(CesarText.fold(t.title)))) {
      final d = _day(t.date);
      if (today.difference(d).inDays < window) byDay[d] = (byDay[d] ?? 0) + t.amount;
    }
    var daily = [for (var i = 0; i < window; i++) byDay[today.subtract(Duration(days: i))] ?? 0.0];
    if (daily.isNotEmpty) {
      final cap = Stats.percentile(daily, 0.95);
      if (cap > 0) daily = daily.map((v) => min(v, cap)).toList();
    }

    final current = txs.where((t) => inMonth(t, today));
    final curFixed = current.where((t) => _isOutflow(t) && recurringKeys.contains(CesarText.fold(t.title))).fold(0.0, (a, t) => a + t.amount);
    final curVar = current.where((t) => _isOutflow(t) && !recurringKeys.contains(CesarText.fold(t.title))).fold(0.0, (a, t) => a + t.amount);
    return FinancialProfile._(
      now: now,
      daysOfData: daysOfData,
      months: months,
      categories: categories,
      recurringExpenses: recurringExpenses,
      recurringIncomes: recurringIncomes,
      dailyVariable: daily,
      currentIncome: current.where((t) => t.type == TransactionType.income).fold(0.0, (a, t) => a + t.amount),
      currentExpenseProrated: curFixed + curVar * daysInMonth / today.day,
    );
  }

  static bool _isOutflow(FinancialTransaction t) =>
      t.type == TransactionType.expense || (t.type == TransactionType.transfer && !t.isInternalTransfer);
}
