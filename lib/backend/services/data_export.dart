import 'dart:convert';

import '../models/financial_transaction.dart';
import '../repositories/financial_repository.dart';

/// "Exportar meus dados" (LGPD): everything in JSON, and the transactions in
/// a CSV that opens in Excel with the accents right (UTF-8 with BOM, ";" as
/// separator and decimal comma, as Excel in Portuguese expects). Pure Dart.
class DataExport {
  DataExport._();

  static const int version = 1;

  /// Every piece of the user's data, as pretty JSON.
  static String toJson(FinancialRepository repo, {DateTime? now}) {
    final data = {
      'app': 'Krezio.ai',
      'exportVersion': version,
      'exportedAt': (now ?? DateTime.now()).toIso8601String(),
      'transactions': repo.transactions.map((t) => t.toJson()).toList(),
      'accounts': repo.accounts.map((a) => a.toJson()).toList(),
      'budgets': repo.budgets.map((b) => b.toJson()).toList(),
      'goals': repo.goals.map((g) => g.toJson()).toList(),
      'reminders': repo.reminders.map((r) => r.toJson()).toList(),
      'categoryMemory': repo.categoryOverrides,
      'preferences': repo.preferences,
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  static String _cell(String v) {
    final needsQuotes = v.contains(';') || v.contains('"') || v.contains('\n') || v.contains('\r');
    final escaped = v.replaceAll('"', '""');
    return needsQuotes ? '"$escaped"' : escaped;
  }

  static String _money(double v) => v.toStringAsFixed(2).replaceAll('.', ',');

  static String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  static const _types = {TransactionType.expense: 'Despesa', TransactionType.income: 'Receita', TransactionType.transfer: 'Transferência'};

  /// Transactions as CSV, newest first, starting with the UTF-8 BOM.
  static String transactionsCsv(FinancialRepository repo) {
    String categoryName(String code) {
      for (final b in repo.budgets) {
        if (b.category == code) return b.name;
      }
      return code;
    }

    String accountName(String id) => repo.accountById(id)?.name ?? id;

    final rows = <List<String>>[
      ['Data', 'Título', 'Tipo', 'Valor', 'Categoria', 'Forma de pagamento', 'Parcelas', 'Conta', 'Recorrente', 'Observações'],
    ];
    final sorted = repo.transactions.toList()..sort((a, b) => b.date.compareTo(a.date));
    for (final t in sorted) {
      rows.add([
        _date(t.date),
        t.title,
        _types[t.type]!,
        _money(t.type == TransactionType.expense ? -t.amount : t.amount),
        categoryName(t.category),
        t.paymentMethodLabel,
        (t.installments ?? 1) > 1 ? '${t.installments}' : '',
        accountName(t.account),
        t.isRecurrent ? 'Sim' : 'Não',
        t.notes ?? '',
      ]);
    }
    return '﻿${rows.map((r) => r.map(_cell).join(';')).join('\r\n')}\r\n';
  }

  /// "krezio-dados-2026-10-16".
  static String fileBase(DateTime now) =>
      'krezio-dados-${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
}
