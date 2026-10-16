import 'dart:math';

import '../../backend/models/financial_reminder.dart';
import '../../backend/models/financial_transaction.dart';
import '../cesar_text.dart';
import 'financial_profile.dart';

/// Money that will come in (positive) or go out (negative) on a known day.
class CashEvent {
  final DateTime day;
  final double amount;
  final String label;
  const CashEvent(this.day, this.amount, this.label);
}

/// The balance, day by day, across many simulated futures.
class ForecastResult {
  final DateTime start;
  final List<double> p10;
  final List<double> p50;
  final List<double> p90;

  /// Lowest balance of each simulation.
  final List<double> minimums;

  /// Balance at the end of the horizon, per simulation.
  final List<double> finals;

  const ForecastResult({required this.start, required this.p10, required this.p50, required this.p90, required this.minimums, required this.finals});

  int get days => p50.length;

  /// Chance (0..1) that the balance never goes below [floor].
  double probAbove(double floor) => minimums.isEmpty ? 1 : minimums.where((m) => m >= floor).length / minimums.length;

  /// Lowest median balance and when it happens.
  ({double value, DateTime day}) get lowestMedian {
    var idx = 0;
    for (var i = 1; i < p50.length; i++) {
      if (p50[i] < p50[idx]) idx = i;
    }
    return (value: p50.isEmpty ? 0 : p50[idx], day: start.add(Duration(days: idx)));
  }

  /// Median balance on [day] (clamped to the horizon).
  double medianOn(DateTime day) => p50.isEmpty ? 0 : p50[day.difference(start).inDays.clamp(0, p50.length - 1)];
  double p10On(DateTime day) => p10.isEmpty ? 0 : p10[day.difference(start).inDays.clamp(0, p10.length - 1)];
}

/// Projects the balance into the future: known events (salary, fixed bills,
/// open bills, extra events like a purchase) plus the variable spending of
/// each day drawn at random from the user's own recent days (bootstrap). Run
/// [simulations] times, it gives a median path, a pessimistic (p10) and an
/// optimistic (p90) one, and the chance of staying above a floor. Pure Dart:
/// the random seed is fixed, so the same data always gives the same answer.
class CashFlowForecast {
  CashFlowForecast._();

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Salary, fixed bills and open bills expected in the next [days] days.
  /// A bill already paid this month (same title) is not counted again.
  static List<CashEvent> knownEvents(
    FinancialProfile p, {
    required Iterable<FinancialTransaction> transactions,
    Iterable<FinancialReminder> openBills = const [],
    required int days,
  }) {
    final today = _day(p.now);
    final end = today.add(Duration(days: days));
    final events = <CashEvent>[];
    final paidThisMonth = {
      for (final t in transactions)
        if (t.date.year == today.year && t.date.month == today.month) CesarText.fold(t.title),
    };
    final billKeys = <String>{};
    for (final b in openBills) {
      final d = _day(b.targetDate).isBefore(today) ? today : _day(b.targetDate);
      if (d.isAfter(end) || (b.amount ?? 0) <= 0) continue;
      events.add(CashEvent(d, -(b.amount!), b.title));
      billKeys.add(CesarText.fold(b.title));
    }
    for (var m = 0; m <= days ~/ 28 + 1; m++) {
      final month = DateTime(today.year, today.month + m);
      final last = DateTime(month.year, month.month + 1, 0).day;
      for (final r in [...p.recurringIncomes, ...p.recurringExpenses]) {
        final d = DateTime(month.year, month.month, r.day.clamp(1, last));
        if (d.isBefore(today) || d.isAfter(end)) continue;
        if (m == 0 && paidThisMonth.contains(r.key)) continue;
        if (!r.income && billKeys.contains(r.key)) continue;
        events.add(CashEvent(d, r.income ? r.amount : -r.amount, r.title));
      }
    }
    return events;
  }

  /// Runs the simulation. [dailyAdjust] is added to each day's variable
  /// spending (negative = spending less, e.g. a cut of R$ 300/month is
  /// -10/day).
  static ForecastResult run(
    FinancialProfile p, {
    required double startBalance,
    required int days,
    required List<CashEvent> events,
    double dailyAdjust = 0,
    int simulations = 400,
    int? seed,
    bool percentiles = true,
  }) {
    final today = _day(p.now);
    final byDay = List<double>.filled(days, 0);
    for (final e in events) {
      final i = _day(e.day).difference(today).inDays;
      if (i >= 0 && i < days) byDay[i] += e.amount;
    }
    final pool = p.dailyVariable;
    final rnd = Random(seed ?? (pool.length * 7919 + days * 31 + startBalance.round()));
    // Only the chance is needed in searches: no day-by-day paths then.
    final paths = percentiles ? List.generate(simulations, (_) => List<double>.filled(days, 0)) : const <List<double>>[];
    final minimums = <double>[];
    final finals = <double>[];
    for (var s = 0; s < simulations; s++) {
      var bal = startBalance;
      var low = startBalance;
      for (var d = 0; d < days; d++) {
        final spend = pool.isEmpty ? 0.0 : pool[rnd.nextInt(pool.length)];
        bal += byDay[d] - max(0.0, spend + dailyAdjust);
        if (percentiles) paths[s][d] = bal;
        if (bal < low) low = bal;
      }
      minimums.add(low);
      finals.add(bal);
    }
    if (!percentiles) {
      return ForecastResult(start: today, p10: const [], p50: const [], p90: const [], minimums: minimums, finals: finals);
    }
    final p10 = List<double>.filled(days, 0), p50 = List<double>.filled(days, 0), p90 = List<double>.filled(days, 0);
    for (var d = 0; d < days; d++) {
      final col = [for (var s = 0; s < simulations; s++) paths[s][d]]..sort();
      p10[d] = col[(simulations * 0.1).floor()];
      p50[d] = col[simulations ~/ 2];
      p90[d] = col[min(simulations - 1, (simulations * 0.9).floor())];
    }
    return ForecastResult(start: today, p10: p10, p50: p50, p90: p90, minimums: minimums, finals: finals);
  }
}
