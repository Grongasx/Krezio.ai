import '../../ai/category_name_matcher.dart';
import '../models/financial_transaction.dart';

/// Period filter of the statement.
enum StatementPeriod { all, thisMonth, lastMonth, custom }

/// The statement's filters. They combine: every one that is set must match.
class StatementFilter {
  final StatementPeriod period;

  /// Inclusive day range, used when [period] is [StatementPeriod.custom].
  final DateTime? from;
  final DateTime? to;
  final String? category;
  final TransactionType? type;
  final String? paymentMethod;
  final bool onlyInstallments;
  final bool onlyRecurrent;
  final String text;

  const StatementFilter({
    this.period = StatementPeriod.all,
    this.from,
    this.to,
    this.category,
    this.type,
    this.paymentMethod,
    this.onlyInstallments = false,
    this.onlyRecurrent = false,
    this.text = '',
  });

  bool get isEmpty =>
      period == StatementPeriod.all &&
      category == null &&
      type == null &&
      paymentMethod == null &&
      !onlyInstallments &&
      !onlyRecurrent &&
      text.trim().isEmpty;

  StatementFilter copyWith({
    StatementPeriod? period,
    DateTime? from,
    DateTime? to,
    String? category,
    TransactionType? type,
    String? paymentMethod,
    bool? onlyInstallments,
    bool? onlyRecurrent,
    String? text,
    bool clearCategory = false,
    bool clearType = false,
    bool clearPayment = false,
  }) {
    return StatementFilter(
      period: period ?? this.period,
      from: from ?? this.from,
      to: to ?? this.to,
      category: clearCategory ? null : category ?? this.category,
      type: clearType ? null : type ?? this.type,
      paymentMethod: clearPayment ? null : paymentMethod ?? this.paymentMethod,
      onlyInstallments: onlyInstallments ?? this.onlyInstallments,
      onlyRecurrent: onlyRecurrent ?? this.onlyRecurrent,
      text: text ?? this.text,
    );
  }
}

/// One day of the statement: its header and the day's total.
class StatementDay {
  final DateTime day;
  final List<FinancialTransaction> transactions;

  const StatementDay(this.day, this.transactions);

  /// Income minus expenses of the day (transfers don't count).
  double get total => StatementQuery.net(transactions);
}

/// Filters, searches and groups the statement. Pure Dart.
class StatementQuery {
  StatementQuery._();

  /// Lowercase and accent-free: "Açougue" and "acougue" are the same.
  static String fold(String text) => CategoryNameMatcher.foldAccents(text.toLowerCase().trim());

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Whether [t] falls in [filter]'s period, relative to [now].
  static bool inPeriod(FinancialTransaction t, StatementFilter filter, DateTime now) {
    final d = _day(t.date);
    switch (filter.period) {
      case StatementPeriod.all:
        return true;
      case StatementPeriod.thisMonth:
        return d.year == now.year && d.month == now.month;
      case StatementPeriod.lastMonth:
        final last = DateTime(now.year, now.month - 1);
        return d.year == last.year && d.month == last.month;
      case StatementPeriod.custom:
        if (filter.from != null && d.isBefore(_day(filter.from!))) return false;
        if (filter.to != null && d.isAfter(_day(filter.to!))) return false;
        return true;
    }
  }

  /// Transactions matching every filter, newest first. [categoryName] gives the
  /// display name of a category code, so the search finds "Mercado" by name.
  static List<FinancialTransaction> apply(
    Iterable<FinancialTransaction> all,
    StatementFilter filter, {
    required DateTime now,
    String Function(String category)? categoryName,
  }) {
    final q = fold(filter.text);
    final result = all.where((t) {
      if (!inPeriod(t, filter, now)) return false;
      if (filter.category != null && t.category != filter.category) return false;
      if (filter.type != null && t.type != filter.type) return false;
      if (filter.paymentMethod != null && t.paymentMethod != filter.paymentMethod) return false;
      if (filter.onlyInstallments && (t.installments ?? 1) <= 1) return false;
      if (filter.onlyRecurrent && !t.isRecurrent) return false;
      if (q.isNotEmpty) {
        final haystack = [
          t.title,
          categoryName?.call(t.category) ?? t.categoryLabel,
          t.bankSource ?? '',
          t.notes ?? '',
        ].map(fold).join(' ');
        if (!q.split(RegExp(r'\s+')).every(haystack.contains)) return false;
      }
      return true;
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    return result;
  }

  /// [sorted] (newest first) grouped by calendar day.
  static List<StatementDay> groupByDay(List<FinancialTransaction> sorted) {
    final days = <StatementDay>[];
    for (final t in sorted) {
      final d = _day(t.date);
      if (days.isEmpty || days.last.day != d) {
        days.add(StatementDay(d, [t]));
      } else {
        days.last.transactions.add(t);
      }
    }
    return days;
  }

  /// Income minus expenses; transfers don't change the total.
  static double net(Iterable<FinancialTransaction> txs) {
    var sum = 0.0;
    for (final t in txs) {
      if (t.type == TransactionType.income) sum += t.amount;
      if (t.type == TransactionType.expense) sum -= t.amount;
    }
    return sum;
  }

  static const _weekdays = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];

  /// "Hoje", "Ontem" or "Seg, 28/09" (with the year when it isn't [now]'s).
  static String dayHeader(DateTime day, DateTime now) {
    final diff = _day(now).difference(_day(day)).inDays;
    if (diff == 0) return 'Hoje';
    if (diff == 1) return 'Ontem';
    final dd = day.day.toString().padLeft(2, '0');
    final mm = day.month.toString().padLeft(2, '0');
    final year = day.year == now.year ? '' : '/${day.year}';
    return '${_weekdays[day.weekday - 1]}, $dd/$mm$year';
  }
}
