import '../models/financial_transaction.dart';

/// One line read from a bank file, before it becomes a transaction.
class ImportedEntry {
  final DateTime date;
  final String description;

  /// Negative = money out, positive = money in.
  final double amount;

  /// The bank's own id for the line (OFX FITID), when there is one.
  final String? bankId;

  /// Already in the app: same bank id, or same day, value and description.
  final bool isDuplicate;

  const ImportedEntry({required this.date, required this.description, required this.amount, this.bankId, this.isDuplicate = false});

  ImportedEntry markDuplicate() => ImportedEntry(date: date, description: description, amount: amount, bankId: bankId, isDuplicate: true);

  /// Stable key used to detect the same line in a second import.
  String get key => bankId != null && bankId!.isNotEmpty
      ? 'ofx:$bankId'
      : 'csv:${date.year}-${date.month}-${date.day}|${amount.toStringAsFixed(2)}|${description.trim().toLowerCase()}';
}

/// Reads bank statements — OFX (most Brazilian banks) and CSV (Nubank,
/// Inter, Itaú, C6 and others, "data;descrição;valor" in any order) — shows a
/// preview and marks lines already imported, so importing the same file twice
/// adds nothing. Pure Dart.
class StatementImport {
  StatementImport._();

  // ───────────────────────── OFX ─────────────────────────

  static List<ImportedEntry> parseOfx(String content) {
    final result = <ImportedEntry>[];
    final blocks = RegExp(r'<STMTTRN>([\s\S]*?)(?:</STMTTRN>|(?=<STMTTRN>)|(?=</BANKTRANLIST>))', caseSensitive: false).allMatches(content);
    for (final b in blocks) {
      final body = b.group(1)!;
      String? tag(String name) =>
          RegExp('<$name>([^<\\r\\n]*)', caseSensitive: false).firstMatch(body)?.group(1)?.trim();
      final rawDate = tag('DTPOSTED');
      final rawAmount = tag('TRNAMT');
      if (rawDate == null || rawAmount == null || rawDate.length < 8) continue;
      final date = DateTime.tryParse('${rawDate.substring(0, 4)}-${rawDate.substring(4, 6)}-${rawDate.substring(6, 8)}');
      final amount = double.tryParse(rawAmount.replaceAll(',', '.'));
      if (date == null || amount == null || amount == 0) continue;
      final desc = (tag('MEMO')?.isNotEmpty ?? false) ? tag('MEMO')! : (tag('NAME') ?? 'Lançamento importado');
      result.add(ImportedEntry(date: date, description: _clean(desc), amount: amount, bankId: tag('FITID')));
    }
    return result;
  }

  // ───────────────────────── CSV ─────────────────────────

  static const _dateHeads = ['data', 'date', 'data lancamento', 'data de lancamento', 'data da compra'];
  static const _descHeads = ['descricao', 'description', 'title', 'historico', 'estabelecimento', 'lancamento', 'titulo'];
  static const _amountHeads = ['valor', 'amount', r'valor (r$)', r'valor r$', 'quantia'];

  static String _fold(String s) {
    const from = 'áàâãéêíóôõúç';
    const to = 'aaaaeeiooouc';
    var r = s.toLowerCase().trim().replaceAll('"', '');
    for (var i = 0; i < from.length; i++) {
      r = r.replaceAll(from[i], to[i]);
    }
    return r;
  }

  static List<String> _split(String line, String sep) {
    final out = <String>[];
    final cur = StringBuffer();
    var quoted = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        if (quoted && i + 1 < line.length && line[i + 1] == '"') {
          cur.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (c == sep && !quoted) {
        out.add(cur.toString());
        cur.clear();
      } else {
        cur.write(c);
      }
    }
    out.add(cur.toString());
    return out.map((s) => s.trim()).toList();
  }

  /// "1.234,56", "-1234.56", "R$ 50,00", "(80,00)" → number.
  static double? parseAmount(String raw) {
    var t = raw.replaceAll(RegExp(r'[R$\s]'), '');
    var negative = false;
    if (t.startsWith('(') && t.endsWith(')')) {
      negative = true;
      t = t.substring(1, t.length - 1);
    }
    if (t.contains(',') && t.contains('.')) {
      t = t.lastIndexOf(',') > t.lastIndexOf('.') ? t.replaceAll('.', '').replaceAll(',', '.') : t.replaceAll(',', '');
    } else if (t.contains(',')) {
      t = t.replaceAll(',', '.');
    }
    final v = double.tryParse(t);
    if (v == null) return null;
    return negative ? -v.abs() : v;
  }

  /// "16/10/2026", "2026-10-16", "16/10/26".
  static DateTime? parseDate(String raw) {
    final t = raw.trim().replaceAll('"', '');
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(t);
    if (iso != null) return DateTime(int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!));
    final br = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2,4})').firstMatch(t);
    if (br != null) {
      var y = int.parse(br[3]!);
      if (y < 100) y += 2000;
      return DateTime(y, int.parse(br[2]!), int.parse(br[1]!));
    }
    return null;
  }

  /// [expensesPositive]: the file lists purchases as positive numbers (credit
  /// card statements like Nubank's) — they are flipped to money out.
  static List<ImportedEntry> parseCsv(String content, {bool expensesPositive = false}) {
    final lines = content.replaceFirst('﻿', '').split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return const [];
    final sep = lines.first.split(';').length >= lines.first.split(',').length ? ';' : ',';
    final head = _split(lines.first, sep).map(_fold).toList();
    int col(List<String> names) => head.indexWhere((h) => names.contains(h));
    var di = col(_dateHeads), si = col(_descHeads), vi = col(_amountHeads);
    var start = 1;
    if (di < 0 || vi < 0) {
      // No header: guess by content (date, description, value).
      di = 0;
      si = 1;
      vi = 2;
      start = 0;
    }
    final result = <ImportedEntry>[];
    for (final line in lines.skip(start)) {
      final cells = _split(line, sep);
      if (cells.length <= [di, vi, si].reduce((a, b) => a > b ? a : b)) continue;
      final date = parseDate(cells[di]);
      var amount = parseAmount(cells[vi]);
      if (date == null || amount == null || amount == 0) continue;
      if (expensesPositive) amount = -amount;
      final desc = si >= 0 ? _clean(cells[si]) : 'Lançamento importado';
      result.add(ImportedEntry(date: date, description: desc.isEmpty ? 'Lançamento importado' : desc, amount: amount));
    }
    return result;
  }

  static String _clean(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return t;
    // "PAG*IFOOD" / "UBER *TRIP" → "Pag Ifood"/"Uber Trip": readable titles.
    final words = t.replaceAll(RegExp(r'[*]+'), ' ').split(' ').where((w) => w.isNotEmpty);
    return words.map((w) => w.length <= 2 && w == w.toUpperCase() ? w : w[0].toUpperCase() + w.substring(1).toLowerCase()).join(' ');
  }

  // ───────────────────────── duplicates and saving ─────────────────────────

  /// Marks entries already in the app (by bank id kept in the notes, or by
  /// same day + value + description) and repeated inside the file itself.
  static List<ImportedEntry> markDuplicates(List<ImportedEntry> entries, Iterable<FinancialTransaction> existing) {
    final known = <String>{};
    for (final t in existing) {
      final id = RegExp(r'importado:(.+)$', multiLine: true).firstMatch(t.notes ?? '')?.group(1);
      if (id != null) known.add(id);
      final signed = t.type == TransactionType.income ? t.amount : -t.amount;
      known.add('csv:${t.date.year}-${t.date.month}-${t.date.day}|${signed.toStringAsFixed(2)}|${t.title.trim().toLowerCase()}');
    }
    return [
      for (final e in entries)
        if (known.contains(e.key) || !known.add(e.key)) e.markDuplicate() else e,
    ];
  }

  /// New entries as transactions (duplicates skipped). The import key is kept
  /// in the notes so a second import of the same file is recognized.
  static List<FinancialTransaction> toTransactions(List<ImportedEntry> entries,
      {required String accountId, String? Function(String description)? categorize, required String Function() newId}) {
    return [
      for (final e in entries.where((e) => !e.isDuplicate))
        FinancialTransaction(
          id: newId(),
          title: e.description,
          amount: e.amount.abs(),
          type: e.amount < 0 ? TransactionType.expense : TransactionType.income,
          category: categorize?.call(e.description) ?? (e.amount < 0 ? 'expense_other' : 'income_other'),
          paymentMethod: 'unknown',
          date: e.date,
          accountId: accountId == 'main' ? null : accountId,
          notes: 'importado:${e.key}',
        ),
    ];
  }
}
