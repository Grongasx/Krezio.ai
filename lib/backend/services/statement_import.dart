import 'dart:convert';
import 'dart:io' show zlib;

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

  // ───────────────────────── PDF (Itaú & Bancos Brasileiros) ─────────────────────────

  static final _ignoredPdfDescriptions = RegExp(
    r'\b(saldo\s+anterior|saldo\s+final|s\s*a\s*l\s*d\s*o|saldo\s+em|saldo\s+disponivel|saldo\s+total|saldo\s+do\s+dia|total\s+de\s+entradas|total\s+de\s+saidas|limite\s+da\s+conta|saldo\s+aplic\s+aut)\b',
    caseSensitive: false,
  );

  /// Extracts readable text from a PDF byte buffer (decompressing FlateDecode/zlib
  /// streams and decoding PDF `Tj` / `TJ` text blocks) and parses Itaú/bank statement lines.
  static List<ImportedEntry> parsePdfBytes(
    List<int> bytes, {
    bool expensesPositive = false,
    int? defaultYear,
  }) {
    final extracted = extractTextFromPdfBytes(bytes);
    return parsePdfText(
      extracted,
      expensesPositive: expensesPositive,
      defaultYear: defaultYear,
    );
  }

  /// Extracts text lines from PDF binary bytes, supporting both compressed
  /// (`FlateDecode` / zlib) and uncompressed PDF content streams.
  static String extractTextFromPdfBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';
    final rawLatin = latin1.decode(bytes, allowInvalid: true);
    final buffer = StringBuffer();

    final streamRegex = RegExp(r'stream\r?\n([\s\S]*?)\r?\nendstream');
    final matches = streamRegex.allMatches(rawLatin).toList();
    if (matches.isEmpty) {
      return _decodePdfTextOperators(rawLatin);
    }

    for (final m in matches) {
      final content = m.group(1)!;
      final streamBytes = latin1.encode(content);
      String decodedStream;
      try {
        final decompressed = zlib.decode(streamBytes);
        decodedStream = latin1.decode(decompressed, allowInvalid: true);
      } catch (_) {
        decodedStream = content;
      }
      final text = _decodePdfTextOperators(decodedStream);
      if (text.trim().isNotEmpty) {
        buffer.writeln(text);
      }
    }

    final result = buffer.toString().trim();
    return result.isNotEmpty ? result : _decodePdfTextOperators(rawLatin);
  }

  static String _decodePdfTextOperators(String stream) {
    final lines = <String>[];
    final currentLine = StringBuffer();

    // If stream has BT..ET blocks or PDF string literals (...), extract them in order.
    final tokenRegex = RegExp(r'\((?:\\.|[^\\)])*\)|\[(?:\s*\((?:\\.|[^\\)])*\)\s*|-?\d+(?:\.\d+)?\s*)+]\s*TJ|\b(?:Td|TD|T\*|ET)\b|\r?\n');
    var foundPdfStrings = false;

    for (final match in tokenRegex.allMatches(stream)) {
      final token = match.group(0)!;
      if (token.startsWith('(') && token.endsWith(')')) {
        foundPdfStrings = true;
        final inner = _unescapePdfString(token.substring(1, token.length - 1));
        if (inner.trim().isNotEmpty) {
          if (currentLine.isNotEmpty && !currentLine.toString().endsWith(' ')) {
            currentLine.write(' ');
          }
          currentLine.write(inner);
        }
      } else if (token.endsWith('TJ')) {
        foundPdfStrings = true;
        final litRegex = RegExp(r'\((?:\\.|[^\\)])*\)');
        final parts = litRegex
            .allMatches(token)
            .map((m) => _unescapePdfString(m.group(0)!.substring(1, m.group(0)!.length - 1)))
            .join('');
        if (parts.trim().isNotEmpty) {
          if (currentLine.isNotEmpty && !currentLine.toString().endsWith(' ')) {
            currentLine.write(' ');
          }
          currentLine.write(parts);
        }
      } else if (token == 'Td' || token == 'TD' || token == 'T*' || token == 'ET') {
        if (currentLine.isNotEmpty) {
          lines.add(currentLine.toString().trim());
          currentLine.clear();
        }
      }
    }
    if (currentLine.isNotEmpty) {
      lines.add(currentLine.toString().trim());
    }

    if (foundPdfStrings && lines.isNotEmpty) {
      return lines.join('\n');
    }
    return stream;
  }

  static String _unescapePdfString(String s) {
    return s
        .replaceAll(r'\(', '(')
        .replaceAll(r'\)', ')')
        .replaceAll(r'\\', '\\')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', ' ');
  }

  /// Parses extracted text from Itaú (checking account and credit card) or other
  /// Brazilian bank PDF statements.
  static List<ImportedEntry> parsePdfText(
    String text, {
    bool expensesPositive = false,
    int? defaultYear,
  }) {
    if (text.trim().isEmpty) return const [];

    // Infer statement year from headers like "01/10/2026" or "Outubro/2026"
    var inferredYear = defaultYear ?? DateTime.now().year;
    final yearMatch = RegExp(r'\b(20\d{2})\b').firstMatch(text);
    if (defaultYear == null && yearMatch != null) {
      inferredYear = int.parse(yearMatch.group(1)!);
    }

    final entries = <ImportedEntry>[];
    final rawLines = text
        .split(RegExp(r'\r?\n'))
        .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((l) => l.isNotEmpty)
        .toList();

    // Matches Itaú & Brazilian bank lines:
    // Examples:
    // "10/10 PIX TRANSF JOAO -150,00"
    // "12/10 RSHOP-MERCADO EXTRA 12/10 89,90 -"
    // "15/10/2026 REMUNERACAO SALARIO 4.500,00"
    // "18/10 SISPAG LUZ 180,45 D"
    // "20/10 TED RECEBIDA 1.200,00 C"
    final lineRegex = RegExp(
      r'^(\d{2}/\d{2}(?:/\d{2,4})?)\s+(.+?)\s+(?:R\$\s*)?(-?\s*(?:\d{1,3}(?:\.\d{3})*|\d+),\d{2})\s*([-+DCdc])?$',
    );

    for (final line in rawLines) {
      final match = lineRegex.firstMatch(line);
      if (match == null) continue;

      final rawDate = match.group(1)!;
      var rawDesc = match.group(2)!.trim();
      final rawVal = match.group(3)!.replaceAll(' ', '');
      final trailingSign = match.group(4)?.toUpperCase();

      // Strip trailing secondary date in Itaú RSHOP lines (e.g. "RSHOP-MERCADO 12/10")
      rawDesc = rawDesc.replaceAll(RegExp(r'\s+\d{2}/\d{2}$'), '').trim();
      // If description ends with a '-' that belonged to the amount (e.g. "PIX JOAO - 150,00")
      var descEndedWithMinus = false;
      if (rawDesc.endsWith(' -') || rawDesc.endsWith('-')) {
        descEndedWithMinus = true;
        rawDesc = rawDesc.substring(0, rawDesc.length - 1).trim();
      }

      if (rawDesc.isEmpty || _ignoredPdfDescriptions.hasMatch(_fold(rawDesc))) {
        continue;
      }

      DateTime? date = parseDate(rawDate);
      if (date == null) {
        final ddmm = RegExp(r'^(\d{2})/(\d{2})$').firstMatch(rawDate);
        if (ddmm != null) {
          date = DateTime(
            inferredYear,
            int.parse(ddmm.group(2)!),
            int.parse(ddmm.group(1)!),
          );
        }
      }
      if (date == null) continue;

      var amount = parseAmount(rawVal);
      if (amount == null || amount == 0) continue;

      final isExplicitNegative = rawVal.startsWith('-') ||
          descEndedWithMinus ||
          trailingSign == '-' ||
          trailingSign == 'D';
      final isExplicitPositive = trailingSign == '+' || trailingSign == 'C';

      if (isExplicitNegative) {
        amount = -amount.abs();
      } else if (isExplicitPositive) {
        amount = amount.abs();
      } else if (expensesPositive) {
        amount = -amount.abs();
      }

      final cleanDesc = _clean(rawDesc);
      entries.add(
        ImportedEntry(
          date: date,
          description: cleanDesc.isEmpty ? 'Lançamento Itaú' : cleanDesc,
          amount: amount,
        ),
      );
    }

    return entries;
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
