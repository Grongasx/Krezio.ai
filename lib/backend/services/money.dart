import 'package:intl/intl.dart';

class Money {
  Money._();

  static final _grouped = NumberFormat('#,##0.00', 'pt_BR');
  static final _ungrouped = NumberFormat('0.00', 'pt_BR');

  static String brl(double amount) {
    // Round half up in cents even when the binary representation is slightly
    // below the half-cent, for example 2611.60 divided into 16 installments.
    final magnitude = amount.abs();
    final cents = magnitude * 100;
    final rounded = cents.isFinite ? (cents + 1e-6).round() / 100 : magnitude;
    final sign = amount < 0 && rounded != 0 ? '-' : '';
    return '${sign}R\$ ${_grouped.format(rounded)}';
  }

  /// Comma decimal without grouping for input fields and CSV.
  static String decimal(double amount) => _ungrouped.format(amount);
}
