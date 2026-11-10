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

/// Automatic Brazilian currency input mask (`4000` -> `4.000,00`, `50,90` -> `50,90`).
class BrlCurrencyInputFormatter extends TextInputFormatter {
  const BrlCurrencyInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final raw = newValue.text.trim();
    if (raw.isEmpty || raw == ',00' || raw == ',') {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }

    // If user typed ',' or '.' right before ',00' to edit cents:
    if (raw.contains(',,') || raw.contains('.,')) {
      final intPart = raw.split(RegExp(r'[,.],')).first;
      final formattedInt = Money.formatIntDigits(intPart);
      final text = '$formattedInt,';
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }

    if (raw.contains(',')) {
      final parts = raw.split(',');
      final intDigits = parts.first.replaceAll(RegExp(r'\D'), '');
      final decDigits = parts.sublist(1).join().replaceAll(RegExp(r'\D'), '');
      if (intDigits.isEmpty && (decDigits.isEmpty || decDigits == '00')) {
        return const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );
      }
      final formattedInt = Money.formatIntDigits(intDigits.isEmpty ? '0' : intDigits);
      final clampedDec = decDigits.length > 2 ? decDigits.substring(0, 2) : decDigits;
      final text = '$formattedInt,$clampedDec';

      // Keep cursor before comma if user was editing integer part before ',00'
      final oldComma = oldValue.text.indexOf(',');
      final wasBeforeComma =
          oldComma >= 0 && oldValue.selection.baseOffset <= oldComma && clampedDec == '00';
      final offset = wasBeforeComma ? formattedInt.length : text.length;
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: offset.clamp(0, text.length)),
      );
    }

    // No comma present (e.g. '4000' -> '4.000,00')
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) {
      return const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }
    final formattedInt = Money.formatIntDigits(digits);
    final text = '$formattedInt,00';
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: formattedInt.length),
    );
  }
}

