import '../models/financial_account.dart';
import '../models/financial_transaction.dart';

/// One line of an invoice: a purchase, or one installment of it.
class InvoiceItem {
  final FinancialTransaction transaction;
  final int installment;
  final int installments;
  final double amount;

  const InvoiceItem(this.transaction, this.installment, this.installments, this.amount);

  /// "Parcela 3/10", or empty for a single payment.
  String get installmentLabel => installments > 1 ? 'Parcela $installment/$installments' : '';
}

/// Credit card invoice math: which invoice a purchase falls in, and what each
/// invoice adds up to. Pure Dart.
class CreditCardInvoice {
  CreditCardInvoice._();

  static DateTime _onDay(int year, int month, int day) {
    final last = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, day.clamp(1, last));
  }

  /// Closing date of the invoice a purchase on [purchase] goes to. A purchase
  /// on the closing day or after it goes to the next invoice.
  static DateTime closingFor(DateTime purchase, int closingDay) {
    final thisMonth = _onDay(purchase.year, purchase.month, closingDay);
    final day = DateTime(purchase.year, purchase.month, purchase.day);
    return day.isBefore(thisMonth) ? thisMonth : _onDay(purchase.year, purchase.month + 1, closingDay);
  }

  /// Due date of the invoice that closes on [closing]: the first [dueDay]
  /// after it.
  static DateTime dueForClosing(DateTime closing, int dueDay) {
    final sameMonth = _onDay(closing.year, closing.month, dueDay);
    return sameMonth.isAfter(closing) ? sameMonth : _onDay(closing.year, closing.month + 1, dueDay);
  }

  /// Due date of the invoice a purchase on [purchase] goes to.
  static DateTime dueFor(DateTime purchase, {required int closingDay, required int dueDay}) =>
      dueForClosing(closingFor(purchase, closingDay), dueDay);

  /// Splits [total] into [n] installments in cents; the rounding goes on the
  /// last one, so they always add up to the total (R$ 100 in 3x =
  /// 33,33 + 33,33 + 33,34).
  static List<double> split(double total, int n) {
    if (n <= 1) return [total];
    final cents = (total * 100).round();
    final base = cents ~/ n;
    return [for (var i = 0; i < n; i++) (i == n - 1 ? cents - base * (n - 1) : base) / 100];
  }

  /// Lines of the invoice of [card] due in [dueMonth]'s month.
  static List<InvoiceItem> items(Iterable<FinancialTransaction> all, FinancialAccount card, DateTime dueMonth) {
    if (card.closingDay == null || card.dueDay == null) return const [];
    final result = <InvoiceItem>[];
    for (final t in all) {
      if (t.accountId != card.id || t.type != TransactionType.expense) continue;
      final n = (t.installments ?? 1).clamp(1, 600);
      final first = dueFor(t.date, closingDay: card.closingDay!, dueDay: card.dueDay!);
      final monthsAfter = (dueMonth.year - first.year) * 12 + dueMonth.month - first.month;
      if (monthsAfter < 0 || monthsAfter >= n) continue;
      result.add(InvoiceItem(t, monthsAfter + 1, n, split(t.amount, n)[monthsAfter]));
    }
    result.sort((a, b) => a.transaction.date.compareTo(b.transaction.date));
    return result;
  }

  /// Total of the invoice of [card] due in [dueMonth]'s month.
  static double total(Iterable<FinancialTransaction> all, FinancialAccount card, DateTime dueMonth) =>
      items(all, card, dueMonth).fold(0.0, (s, i) => s + i.amount);

  /// Due date of the invoice of [card] due in [dueMonth]'s month.
  static DateTime dueDate(FinancialAccount card, DateTime dueMonth) => _onDay(dueMonth.year, dueMonth.month, card.dueDay ?? 1);
}
