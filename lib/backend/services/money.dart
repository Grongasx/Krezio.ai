import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

class Money {
  Money._();

  static final _grouped = NumberFormat('#,##0.00', 'pt_BR');
  static final _ungrouped = NumberFormat('0.00', 'pt_BR');
  static final _intGrouped = NumberFormat('#,##0', 'pt_BR');

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

  /// Grouped Brazilian decimal without the `R$ ` prefix (e.g. `4.000,00`).
  static String groupedDecimal(double amount) => _grouped.format(amount);

  /// Formats an integer string with Brazilian thousand dots (e.g. `4000` -> `4.000`).
  static String formatIntDigits(String digits) {
    final cleaned = digits.replaceAll(RegExp(r'\D'), '');
    if (cleaned.isEmpty) return '0';
    final parsed = int.tryParse(cleaned) ?? 0;
    return _intGrouped.format(parsed);
  }

  /// Parses any Brazilian or standard numeric string (e.g. `R$ 4.000,00`, `4.000,00`, `50,90`, `4000`) into a double.
  static double? parse(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^\d.,-]'), '').trim();
    if (cleaned.isEmpty) return null;
    if (cleaned.contains(',')) {
      final normalized = cleaned.replaceAll('.', '').replaceAll(',', '.');
      return double.tryParse(normalized);
    }
    // Check if dots are thousand separators (e.g. 4.000)
    if (RegExp(r'^\d{1,3}(\.\d{3})+$').hasMatch(cleaned)) {
      return double.tryParse(cleaned.replaceAll('.', ''));
    }
    return double.tryParse(cleaned);
  }
}

/// Automatic Brazilian currency input mask, filled from the cents like a
/// bank app: typing `4` → `0,04`, `45` → `0,45`, `4500` → `45,00`,
/// `400000` → `4.000,00`. Backspace removes the last digit.
class BrlCurrencyInputFormatter extends TextInputFormatter {
  const BrlCurrencyInputFormatter();

  static String _digits(String s) => s.replaceAll(RegExp(r'\D'), '');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = _digits(newValue.text);
    final oldDigits = _digits(oldValue.text);

    // Backspace over a separator ("." or ","): drop the last digit instead,
    // otherwise the deletion would be invisible.
    if (newValue.text.length < oldValue.text.length && digits == oldDigits && digits.isNotEmpty) {
      digits = digits.substring(0, digits.length - 1);
    }

    digits = digits.replaceFirst(RegExp(r'^0+'), '');
    if (digits.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }
    // Cap at 13 digits (R$ 99.999.999.999,99) to stay inside int precision.
    if (digits.length > 13) digits = digits.substring(0, 13);

    final cents = int.parse(digits);
    final text = Money.groupedDecimal(cents / 100);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

