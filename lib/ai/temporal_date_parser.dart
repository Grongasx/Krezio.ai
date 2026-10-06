/// Date range result returned by [TemporalDateParser].
class DateRangeResult {
  final DateTime start;
  final DateTime end;
  final String label;
  final String matchedExpression;

  const DateRangeResult({
    required this.start,
    required this.end,
    required this.label,
    required this.matchedExpression,
  });

  bool contains(DateTime date) {
    return (date.isAfter(start) || date.isAtSameMomentAs(start)) &&
        (date.isBefore(end) || date.isAtSameMomentAs(end));
  }

  @override
  String toString() => 'DateRangeResult($label: ${start.toIso8601String()} - ${end.toIso8601String()})';
}

/// Advanced deterministic temporal parser for Portuguese relative financial expressions.
///
/// Parses natural temporal filters like:
/// - "essa semana", "esta semana", "semana que vem", "semana passada"
/// - "esse mês", "este mês", "mês que vem", "mês passado"
/// - "começo do mês que vem", "início do mês que vem", "fim do mês"
/// - "hoje", "amanhã", "ontem", "próximos 15 dias"
/// - "em janeiro", "em dezembro deste ano"
class TemporalDateParser {
  /// Parses temporal expressions found in [text].
  /// Returns `null` if no relative temporal expression is detected.
  static DateRangeResult? parse(String text, {DateTime? referenceDate}) {
    final now = referenceDate ?? DateTime.now();
    final lower = text.toLowerCase().trim();

    // 1. "começo do mês que vem" / "início do mês que vem"
    if (RegExp(r'(?:come[çc]o|come[çc]inho|in[íi]cio)\s+do\s+m[êe]s\s+(?:que|q)\s+vem|(?:come[çc]o|come[çc]inho|in[íi]cio)\s+do\s+pr[óo]ximo\s+m[êe]s').hasMatch(lower)) {
      final nextMonth = DateTime(now.year, now.month + 1, 1);
      final start = DateTime(nextMonth.year, nextMonth.month, 1, 0, 0, 0);
      final end = DateTime(nextMonth.year, nextMonth.month, 10, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'início do próximo mês (dias 1 a 10)',
        matchedExpression: 'começo do mês que vem',
      );
    }

    // 2. "começo deste mês" / "início do mês" / "começo desse mês"
    if (RegExp(r'(?:come[çc]o|come[çc]inho|in[íi]cio)\s+(?:de[sz]te|do|desse)\s+m[êe]s').hasMatch(lower)) {
      final start = DateTime(now.year, now.month, 1, 0, 0, 0);
      final end = DateTime(now.year, now.month, 10, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'início deste mês (dias 1 a 10)',
        matchedExpression: 'início deste mês',
      );
    }

    // 3. "fim do mês que vem" / "final do próximo mês"
    if (RegExp(r'(?:fim|final)\s+do\s+(?:m[êe]s\s+(?:que|q)\s+vem|pr[óo]ximo\s+m[êe]s)').hasMatch(lower)) {
      final nextMonth = DateTime(now.year, now.month + 1, 1);
      final lastDay = DateTime(nextMonth.year, nextMonth.month + 1, 0).day;
      final start = DateTime(nextMonth.year, nextMonth.month, 20, 0, 0, 0);
      final end = DateTime(nextMonth.year, nextMonth.month, lastDay, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'final do próximo mês (dia 20 ao fim)',
        matchedExpression: 'fim do mês que vem',
      );
    }

    // 4. "fim do mês" / "fim deste mês" / "final desse mês"
    if (RegExp(r'(?:fim|final)\s+(?:do|de[sz]te|desse)\s+m[êe]s').hasMatch(lower)) {
      final lastDay = DateTime(now.year, now.month + 1, 0).day;
      final start = DateTime(now.year, now.month, 20, 0, 0, 0);
      final end = DateTime(now.year, now.month, lastDay, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'final deste mês (dia 20 ao fim)',
        matchedExpression: 'fim deste mês',
      );
    }

    // 5. "essa semana" / "esta semana"
    if (RegExp(r'\b(?:es[st]a\s+s[e]?mana|n(?:es[st]a|essa)\s+s[e]?mana)\b').hasMatch(lower)) {
      final weekday = now.weekday; // 1 = Mon, 7 = Sun
      final monday = now.subtract(Duration(days: weekday - 1));
      final sunday = monday.add(const Duration(days: 6));
      final start = DateTime(monday.year, monday.month, monday.day, 0, 0, 0);
      final end = DateTime(sunday.year, sunday.month, sunday.day, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'esta semana',
        matchedExpression: 'esta semana',
      );
    }

    // 6. "semana que vem" / "próxima semana"
    if (RegExp(r'\b(?:s[e]?mana\s+(?:que|q)\s+vem|pr[óo]xima\s+s[e]?mana)\b').hasMatch(lower)) {
      final weekday = now.weekday;
      final nextMonday = now.add(Duration(days: 8 - weekday));
      final nextSunday = nextMonday.add(const Duration(days: 6));
      final start = DateTime(nextMonday.year, nextMonday.month, nextMonday.day, 0, 0, 0);
      final end = DateTime(nextSunday.year, nextSunday.month, nextSunday.day, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'próxima semana',
        matchedExpression: 'semana que vem',
      );
    }

    // 7. "semana passada" / "última semana"
    if (RegExp(r'\b(?:s[e]?mana\s+passada|[úu]ltima\s+s[e]?mana)\b').hasMatch(lower)) {
      final weekday = now.weekday;
      final lastMonday = now.subtract(Duration(days: weekday + 6));
      final lastSunday = lastMonday.add(const Duration(days: 6));
      final start = DateTime(lastMonday.year, lastMonday.month, lastMonday.day, 0, 0, 0);
      final end = DateTime(lastSunday.year, lastSunday.month, lastSunday.day, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'semana passada',
        matchedExpression: 'semana passada',
      );
    }

    // 8. "mês que vem" / "próximo mês"
    if (RegExp(r'\b(?:m[êe]s\s+(?:que|q)\s+vem|pr[óo]ximo\s+m[êe]s)\b').hasMatch(lower)) {
      final nextMonth = DateTime(now.year, now.month + 1, 1);
      final lastDay = DateTime(nextMonth.year, nextMonth.month + 1, 0).day;
      final start = DateTime(nextMonth.year, nextMonth.month, 1, 0, 0, 0);
      final end = DateTime(nextMonth.year, nextMonth.month, lastDay, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'próximo mês',
        matchedExpression: 'mês que vem',
      );
    }

    // 9. "esse mês" / "este mês"
    if (RegExp(r'\b(?:es[st]e\s+m[êe]s|n(?:es[st]e|esse)\s+m[êe]s)\b').hasMatch(lower)) {
      final lastDay = DateTime(now.year, now.month + 1, 0).day;
      final start = DateTime(now.year, now.month, 1, 0, 0, 0);
      final end = DateTime(now.year, now.month, lastDay, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'este mês',
        matchedExpression: 'este mês',
      );
    }

    // 10. "mês passado" / "último mês"
    if (RegExp(r'\b(?:m[êe]s\s+passado|[úu]ltimo\s+m[êe]s)\b').hasMatch(lower)) {
      final prevMonth = DateTime(now.year, now.month - 1, 1);
      final lastDay = DateTime(prevMonth.year, prevMonth.month + 1, 0).day;
      final start = DateTime(prevMonth.year, prevMonth.month, 1, 0, 0, 0);
      final end = DateTime(prevMonth.year, prevMonth.month, lastDay, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'mês passado',
        matchedExpression: 'mês passado',
      );
    }

    // 11. "hoje"
    if (RegExp(r'\bhoje\b').hasMatch(lower)) {
      final start = DateTime(now.year, now.month, now.day, 0, 0, 0);
      final end = DateTime(now.year, now.month, now.day, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'hoje',
        matchedExpression: 'hoje',
      );
    }

    // 12. "amanhã"
    if (RegExp(r'\bamanh[ãa]\b').hasMatch(lower)) {
      final tm = now.add(const Duration(days: 1));
      final start = DateTime(tm.year, tm.month, tm.day, 0, 0, 0);
      final end = DateTime(tm.year, tm.month, tm.day, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'amanhã',
        matchedExpression: 'amanhã',
      );
    }

    // 13. "ontem"
    if (RegExp(r'\bontem\b').hasMatch(lower)) {
      final y = now.subtract(const Duration(days: 1));
      final start = DateTime(y.year, y.month, y.day, 0, 0, 0);
      final end = DateTime(y.year, y.month, y.day, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'ontem',
        matchedExpression: 'ontem',
      );
    }

    // 14. "próximos (\d+) dias" / "ultimos (\d+) dias"
    final nextDaysMatch = RegExp(r'pr[óo]ximos?\s+(\d+)\s+dias').firstMatch(lower);
    if (nextDaysMatch != null) {
      final days = int.tryParse(nextDaysMatch.group(1)!) ?? 7;
      final start = DateTime(now.year, now.month, now.day, 0, 0, 0);
      final future = now.add(Duration(days: days));
      final end = DateTime(future.year, future.month, future.day, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'próximos $days dias',
        matchedExpression: nextDaysMatch.group(0)!,
      );
    }

    final lastDaysMatch = RegExp(r'[úu]ltimos?\s+(\d+)\s+dias').firstMatch(lower);
    if (lastDaysMatch != null) {
      final days = int.tryParse(lastDaysMatch.group(1)!) ?? 7;
      final past = now.subtract(Duration(days: days));
      final start = DateTime(past.year, past.month, past.day, 0, 0, 0);
      final end = DateTime(now.year, now.month, now.day, 23, 59, 59);
      return DateRangeResult(
        start: start,
        end: end,
        label: 'últimos $days dias',
        matchedExpression: lastDaysMatch.group(0)!,
      );
    }

    // 15. Named months: "em janeiro", "em fevereiro", etc.
    final months = {
      'janeiro': 1,
      'fevereiro': 2,
      'mar[çc]o': 3,
      'abril': 4,
      'maio': 5,
      'junho': 6,
      'julho': 7,
      'agosto': 8,
      'setembro': 9,
      'outubro': 10,
      'novembro': 11,
      'dezembro': 12,
    };

    for (final entry in months.entries) {
      if (RegExp('\\b(?:em|no\\s+m[êe]s\\s+de)\\s+${entry.key}\\b').hasMatch(lower)) {
        final monthNum = entry.value;
        var year = now.year;
        // If the month has already passed significantly (e.g. asking in Nov about Jan), assume current year unless specified
        final lastDay = DateTime(year, monthNum + 1, 0).day;
        final start = DateTime(year, monthNum, 1, 0, 0, 0);
        final end = DateTime(year, monthNum, lastDay, 23, 59, 59);
        return DateRangeResult(
          start: start,
          end: end,
          label: 'em ${entry.key.replaceAll('[çc]', 'ç')}',
          matchedExpression: 'no mês especificado',
        );
      }
    }

    return null;
  }
}

/// The day (or span) a sentence says something happened on — "ontem",
/// "segunda", "sábado passado", "há 3 dias", "31/08", "dia 28", "mês
/// passado", "amanhã". Shared by the reference resolver ("o uber de
/// segunda") and by the engine when recording a new entry (CHAOS-R3-002), so
/// both read dates the same way.
class SpokenDay {
  /// First instant of the day/span.
  final DateTime start;

  /// Last instant (23:59:59) of the day/span.
  final DateTime end;

  /// "de ontem", "de segunda", "do dia 28", "de 31/08", "do mês passado".
  final String label;

  /// The words that said it, as found in the simplified text (to strip them).
  final String matched;

  /// A span of days ("semana passada", "mês passado"), not one day.
  final bool isRange;

  const SpokenDay({required this.start, required this.end, required this.label, required this.matched, this.isRange = false});

  /// Whole days from [today] to [start] (negative = past).
  int offsetFrom(DateTime today) =>
      DateTime.utc(start.year, start.month, start.day).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
}

/// Result of [SpokenDayParser.parse]: a day, or why the date said can't exist.
class SpokenDayResult {
  final SpokenDay? day;

  /// "setembro não tem dia 31", "o mês 13 não existe", "não existe dia 45".
  final String? invalid;

  /// The words that said the invalid date (to strip them).
  final String? matched;

  const SpokenDayResult({this.day, this.invalid, this.matched});
}

class SpokenDayParser {
  SpokenDayParser._();

  static const _weekdays = {
    'segunda': DateTime.monday, 'terca': DateTime.tuesday, 'quarta': DateTime.wednesday, 'quinta': DateTime.thursday,
    'sexta': DateTime.friday, 'sabado': DateTime.saturday, 'domingo': DateTime.sunday,
  };

  static const _monthNames = [
    'janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro',
  ];

  static int _daysIn(int year, int month) => DateTime(year, month + 1, 0).day;

  static DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static SpokenDay _one(DateTime d, String label, String matched) =>
      SpokenDay(start: _dayOnly(d), end: DateTime(d.year, d.month, d.day, 23, 59, 59), label: label, matched: matched);

  /// "segunda-feira" → "segunda", so "a feira" alone stays a record's name.
  /// The augmentative is the same day too: "domingão", "sabadão",
  /// "sextona" (ACC-B-003).
  static String normalizeWeekdays(String s) => s
      // "trasanteontem", "trasantontem", "tras-anteontem", "antes de
      // anteontem": three days ago, said as such (ACC-C-005). Read before
      // "anteontem", which they contain.
      .replaceAll(threeDaysAgo, 'ha 3 dias')
      .replaceAllMapped(RegExp(r'\b(segunda|terca|quarta|quinta|sexta)\s*-?\s*feira\b'), (m) => m.group(1)!)
      .replaceAllMapped(RegExp(r'\b(?:(doming|sabad)(?:ao|aum)|(segund|terc|quart|quint|sext)ona)\b'),
          (m) => m.group(1) != null ? (m.group(1) == 'sabad' ? 'sabado' : 'domingo') : '${m.group(2)}a');

  /// The day before "anteontem", in its spoken and misspelled forms (folded).
  static final threeDaysAgo = RegExp(
      r'\b(?:tr[ae]s\s*-?\s*an?t[ei]?\s*-?\s*onte[mn]?|tr[ae]s\s*-?\s*antes\s*-?\s*de\s*-?\s*ontem|antes\s+de\s+ante\s*-?\s*ontem|antes\s+de\s+antiontem)\b');

  /// Numbers of days said in words ("há dois dias", "faz três dias").
  static const _countWords = {
    'um': 1, 'uma': 1, 'dois': 2, 'duas': 2, 'tres': 3, 'quatro': 4, 'cinco': 5, 'seis': 6, 'sete': 7, 'oito': 8, 'nove': 9,
    'dez': 10, 'onze': 11, 'doze': 12, 'treze': 13, 'catorze': 14, 'quatorze': 14, 'quinze': 15, 'vinte': 20, 'trinta': 30,
  };
  static const _count = r'(\d{1,4}|um|uma|dois|duas|tres|quatro|cinco|seis|sete|oito|nove|dez|onze|doze|treze|catorze|quatorze|quinze|vinte|trinta)';
  static int _countValue(String w) => _countWords[w] ?? int.parse(w);

  static const _monthPattern = r'(janeiro|fevereiro|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)';
  static const _monthKeys = [
    'janeiro', 'fevereiro', 'marco', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro',
  ];

  static SpokenDay _range(DateTime start, DateTime end, String label, String matched) =>
      SpokenDay(start: _dayOnly(start), end: DateTime(end.year, end.month, end.day, 23, 59, 59), label: label, matched: matched, isRange: true);

  /// Reads the date in [s] — lowercase, accents folded, weekdays normalized
  /// with [normalizeWeekdays] — relative to [now]. Past-looking forms point
  /// back: a weekday is its last occurrence 1–7 days ago, "dia N" the most
  /// recent day N (this month if it has passed, else last month), "dd/mm"
  /// still ahead this year is last year's. With [allowFuture], "amanhã",
  /// "depois de amanhã", "próxima sexta", "semana/mês que vem", "daqui a N
  /// dias" are read too (their [SpokenDay.start] is after today); without
  /// it, those future forms are not a date at all. [skipDayNumber]: "dia
  /// N"/"dd/mm" belong to something else (a recurring due day) and are not
  /// read. Null when no date is said.
  static SpokenDayResult? parse(String s, {required DateTime now, bool allowFuture = false, bool skipDayNumber = false}) {
    final today = _dayOnly(now);
    RegExpMatch? m;

    if ((m = RegExp(r'\bante\s*-?\s*ontem\b|\bantes\s+de\s+ontem\b|\bantiotem\b|\banti-ontem\b').firstMatch(s)) != null) {
      return SpokenDayResult(day: _one(today.subtract(const Duration(days: 2)), 'de anteontem', m!.group(0)!));
    }
    if ((m = RegExp(r'\bdepois\s+de\s+amanha\b').firstMatch(s)) != null) {
      if (!allowFuture) return null;
      return SpokenDayResult(day: _one(DateTime(today.year, today.month, today.day + 2), 'de depois de amanhã', m!.group(0)!));
    }
    if (allowFuture && (m = RegExp(r'\bamanha\b').firstMatch(s)) != null) {
      return SpokenDayResult(day: _one(DateTime(today.year, today.month, today.day + 1), 'de amanhã', m!.group(0)!));
    }
    if ((m = RegExp(r'\bontem\b').firstMatch(s)) != null) {
      return SpokenDayResult(day: _one(today.subtract(const Duration(days: 1)), 'de ontem', m!.group(0)!));
    }
    if ((m = RegExp(r'\bhoje\b').firstMatch(s)) != null) {
      return SpokenDayResult(day: _one(today, 'de hoje', m!.group(0)!));
    }
    // "há 3 dias", "3 dias atrás", "faz dois dias", "tem 6 dias que" (not
    // "tem 30 dias de garantia", "tem 3 dias pra pagar"), "uns três dias
    // atrás", "gastei 80 tem quatro dias no pix" (ACC-A-003).
    if ((m = RegExp('\\b(?:ha|faz)\\s+(?:uns\\s+|umas\\s+)?$_count\\s+dias?\\b|'
                '\\btem\\s+(?:uns\\s+|umas\\s+)?$_count\\s+dias?(?:\\s+que\\b|(?=\\s*(?:[,.;!]|\$|(?:no|na|em|via|pelo|pela)\\s|tudo\\b|'
                // "tem uns 3 dias paguei 65": the entry's own verb right after.
                '(?:eu\\s+)?[a-z]{2,}(?:ei|ou|eu|iu|amos)\\b)))|'
                '\\b(?:uns\\s+)?$_count\\s+dias?\\s+atras\\b')
            .firstMatch(s)) !=
        null) {
      final n = _countValue(m!.group(1) ?? m.group(2) ?? m.group(3)!);
      if (n > 366) return SpokenDayResult(invalid: 'há $n dias é mais de um ano atrás', matched: m.group(0));
      return SpokenDayResult(day: _one(DateTime(today.year, today.month, today.day - n), 'de $n dias atrás', m.group(0)!));
    }
    // "daqui a 3 dias": ahead.
    if ((m = RegExp('\\bdaqui\\s+a\\s+$_count\\s+dias?\\b').firstMatch(s)) != null) {
      if (!allowFuture) return null;
      final n = _countValue(m!.group(1)!);
      return SpokenDayResult(day: _one(DateTime(today.year, today.month, today.day + n), 'de daqui a $n dias', m.group(0)!));
    }
    // "semana passada na terça", "na terça da semana retrasada": that day of
    // that week — not the whole week, nor "7 days ago" (ACC-B-004).
    if ((m = RegExp(r'\b(?:semana\s+(passada|retrasada)|ultima\s+semana)\s*,?\s+(?:n[ao]s?\s+|de\s+|em\s+)?'
                r'(segunda|terca|quarta|quinta|sexta|sabado|domingo)\b|'
                r'\b(segunda|terca|quarta|quinta|sexta|sabado|domingo)\s+(?:d[ao]\s+|na\s+)?semana\s+(passada|retrasada)\b')
            .firstMatch(s)) !=
        null) {
      final which = m!.group(1) ?? m.group(4) ?? 'passada';
      final name = m.group(2) ?? m.group(3)!;
      final monday = today.subtract(Duration(days: today.weekday - 1 + (which == 'retrasada' ? 14 : 7)));
      final d = monday.add(Duration(days: _weekdays[name]! - 1));
      final label = name.replaceAll('terca', 'terça').replaceAll('sabado', 'sábado');
      return SpokenDayResult(day: _one(d, 'de $label da semana $which', m.group(0)!));
    }
    if ((m = RegExp(r'\bsemana\s+passada\b|\bultima\s+semana\b').firstMatch(s)) != null) {
      final monday = today.subtract(Duration(days: today.weekday - 1 + 7));
      return SpokenDayResult(day: _range(monday, DateTime(monday.year, monday.month, monday.day + 6), 'da semana passada', m!.group(0)!));
    }
    if ((m = RegExp(r'\bsemana\s+retrasada\b').firstMatch(s)) != null) {
      final monday = today.subtract(Duration(days: today.weekday - 1 + 14));
      return SpokenDayResult(day: _range(monday, DateTime(monday.year, monday.month, monday.day + 6), 'da semana retrasada', m!.group(0)!));
    }
    if ((m = RegExp(r'\bsemana\s+que\s+vem\b|\bproxima\s+semana\b').firstMatch(s)) != null) {
      if (!allowFuture) return null;
      final monday = today.add(Duration(days: 8 - today.weekday));
      return SpokenDayResult(day: _range(monday, DateTime(monday.year, monday.month, monday.day + 6), 'da semana que vem', m!.group(0)!));
    }
    // "dia 20 do mês passado": that day, not the whole month (ACC-A-019).
    if (!skipDayNumber && (m = RegExp(r'\bdia\s+(\d{1,2})\s+do\s+mes\s+(passado|retrasado)\b').firstMatch(s)) != null) {
      final n = int.parse(m!.group(1)!);
      final back = m.group(2) == 'passado' ? 1 : 2;
      final first = DateTime(now.year, now.month - back, 1);
      if (n < 1 || n > _daysIn(first.year, first.month)) {
        return SpokenDayResult(invalid: '${_monthNames[first.month - 1]} não tem dia $n', matched: m.group(0));
      }
      return SpokenDayResult(day: _one(DateTime(first.year, first.month, n), 'do dia $n do mês ${m.group(2)}', m.group(0)!));
    }
    if ((m = RegExp(r'\bmes\s+passado\b|\bultimo\s+mes\b').firstMatch(s)) != null) {
      return SpokenDayResult(
        day: _range(DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 0), 'do mês passado', m!.group(0)!),
      );
    }
    if ((m = RegExp(r'\bmes\s+retrasado\b').firstMatch(s)) != null) {
      return SpokenDayResult(
        day: _range(DateTime(now.year, now.month - 2, 1), DateTime(now.year, now.month - 1, 0), 'do mês retrasado', m!.group(0)!),
      );
    }
    if ((m = RegExp(r'\bmes\s+que\s+vem\b|\bproximo\s+mes\b').firstMatch(s)) != null) {
      if (!allowFuture) return null;
      return SpokenDayResult(
        day: _range(DateTime(now.year, now.month + 1, 1), DateTime(now.year, now.month + 2, 0), 'do mês que vem', m!.group(0)!),
      );
    }
    // "fim de semana": Saturday or Sunday — a span, asked about when
    // recording (it used to be "3 days ago" whatever today was).
    if ((m = RegExp(r'\bfim\s+de\s+semana(?:\s+passado)?\b|\bfds\b').firstMatch(s)) != null) {
      final back = today.weekday == DateTime.sunday ? 1 : (today.weekday == DateTime.saturday ? 0 : today.weekday + 1);
      final saturday = today.subtract(Duration(days: back));
      final sunday = saturday.add(const Duration(days: 1));
      return SpokenDayResult(day: _range(saturday, sunday.isAfter(today) ? today : sunday, 'do fim de semana', m!.group(0)!));
    }

    if (!skipDayNumber) {
      // "15 de agosto", "3 de março": like a dd/mm.
      // …but not a street or shop named after a date ("rua 25 de março",
      // "avenida 7 de setembro", "na 25 de março") (ACC-B-005, CHAOS-B-003).
      final named = RegExp('\\b(\\d{1,2})\\s+de\\s+$_monthPattern\\b')
          .allMatches(s)
          .where((x) => !isPlaceBeforeNamedDate(s.substring(0, x.start)))
          .firstOrNull;
      if (named != null) {
        return _dayMonth(int.parse(named.group(1)!), _monthKeys.indexOf(named.group(2)!) + 1, named.group(0)!, today, now, allowFuture);
      }
    }
    final dm = skipDayNumber ? null : dateLikeDayMonth(s);
    final dn = skipDayNumber ? null : RegExp(r'\bdia\s+(\d{1,2})\b').firstMatch(s);
    // "segunda via", "quinta parcela", "toda sexta" are not a past weekday.
    final wd = RegExp(r'(?<!\btod[ao]s?\s)(?<!\bas\s)\b(segunda|terca|quarta|quinta|sexta|sabado|domingo)\b'
            // "quinta avenida" is a street (CHAOS-B-017).
            r'(?!\s+(?:via|vez|parcela|prestacao|mao|opcao|chamada|etapa|fase|dose|quinzena|semana|hora|colocad[oa]|avenida|rua|praca)\b)')
        .firstMatch(s);
    if (dm != null) {
      return _dayMonth(int.parse(dm.group(1)!), int.parse(dm.group(2)!), dm.group(0)!, today, now, allowFuture);
    }
    if (dn != null) {
      // "dia N" = the most recent day N: this month if it has passed,
      // otherwise last month — which must have that day.
      final n = int.parse(dn.group(1)!);
      var year = now.year, month = now.month;
      if (n > today.day) {
        month--;
        if (month == 0) {
          month = 12;
          year--;
        }
      }
      if (n < 1 || n > _daysIn(year, month)) {
        return SpokenDayResult(
          invalid: n < 1 || n > 31 ? 'não existe dia $n' : '${_monthNames[month - 1]} não tem dia $n',
          matched: dn.group(0),
        );
      }
      return SpokenDayResult(day: _one(DateTime(year, month, n), 'do dia $n', dn.group(0)!));
    }
    if (wd != null) {
      final name = wd.group(1)!;
      final target = _weekdays[name]!;
      final label = name.replaceAll('terca', 'terça').replaceAll('sabado', 'sábado');
      // "próxima sexta", "sexta que vem": ahead, not the last one (ACC-A-004).
      final ahead = RegExp('\\bproxim[oa]\\s+$name\\b|\\b$name\\s+que\\s+vem\\b').firstMatch(s);
      if (ahead != null) {
        if (!allowFuture) return null;
        var fwd = (target - today.weekday) % 7;
        if (fwd == 0) fwd = 7;
        return SpokenDayResult(day: _one(DateTime(today.year, today.month, today.day + fwd), 'de $label que vem', ahead.group(0)!));
      }
      var back = (today.weekday - target) % 7;
      if (back == 0) back = 7;
      final passada = RegExp('\\b$name\\s+(?:passad[oa]|retrasad[oa])\\b').firstMatch(s);
      if (passada != null && passada.group(0)!.contains('retrasad')) back += 7;
      return SpokenDayResult(day: _one(today.subtract(Duration(days: back)), 'de $label', passada?.group(0) ?? wd.group(0)!));
    }
    return null;
  }

  /// Whether the text right before a "N de <mês>" makes it the name of a
  /// place: a street/building noun ("rua", "avenida", "praça", "loja"…) or a
  /// feminine article ("na/da 25 de março" — a date is "no dia"/"em").
  static bool isPlaceBeforeNamedDate(String before) => RegExp(
          r'\b(?:rua|r|avenida|av|praca|travessa|tv|alameda|estrada|rodovia|largo|ladeira|viela|loja|lojas|shopping|galeria|'
          r'edificio|condominio|colegio|escola|hospital|vila|bairro|jardim|parque|ponte|terminal|estacao|viaduto|praia|na|da|pela)'
          r'\s+(?:d[aeo]s?\s+)?$')
      .hasMatch(before);

  /// A "d/m" that reads as a date — not "parcela 3/10", "nota 10/10",
  /// "episódio 3/8" (a count of a total), "1/2 kg" (a measure) nor "1/4 de
  /// queijo" (a fraction) (CHAOS-A-014).
  static RegExpMatch? dateLikeDayMonth(String s) {
    for (final m in RegExp(r'\b(\d{1,2})/(\d{1,2})\b(?!/\d)').allMatches(s)) {
      final before = s.substring(0, m.start);
      final after = s.substring(m.end);
      final dateCue = RegExp(r'\b(?:dia|em|de|desde|ate|data|no\s+dia)\s*$').hasMatch(before);
      // A count of a total, a numbering, a size or a score: "aula 5/8",
      // "sessão 4/6", "plantão 12/12", "o jogo terminou 3/1" (CHAOS-B-004).
      if (RegExp(r'\b(?:parcelas?|prestac\w*|nota|n[ºo°]|numero|episodio|capitulo|temporada|pagina|questao|item|fase|etapa|nivel|'
              r'aulas?|sess(?:ao|oes)|rodadas?|plantao|plantoes|turnos?|placar|partida|jogo|turma|modulo|serie|versao|tamanho|'
              r'numeracao|tenis|sapatos?|chuteira|camisa|terminou|ficou|acabou|venceu|perdeu|empatou|ganhou)\s*$')
          .hasMatch(before)) {
        continue;
      }
      if (RegExp(r'^\s*(?:ml|l|kg|g|mg|litros?|quilos?|gramas?|xicaras?|colher\w*|dz|duzias?|pedacos?)\b').hasMatch(after)) continue;
      final d = int.parse(m.group(1)!), mo = int.parse(m.group(2)!);
      // "tênis 40/41" (a size) with no date cue: no month/day that big (CHAOS-B-023).
      if (!dateCue && (mo > 12 || d > 31)) continue;
      // "1/2", "1/4", "3/4" with no date cue: a fraction.
      if (!dateCue && d < mo && mo <= 4) continue;
      return m;
    }
    // A full date "15/09/2026" is always one.
    return RegExp(r'\b(\d{1,2})/(\d{1,2})/\d{2,4}\b').firstMatch(s);
  }

  /// Day [dd] of month [mm] as said without a year: this year's if it has
  /// passed; if it is still ahead, last year's only when that is recent
  /// (the "31/12" said on 1 January) — otherwise, with [allowFuture], it is
  /// the day ahead (asked about), never a date a year ago in silence.
  static SpokenDayResult _dayMonth(int dd, int mm, String matched, DateTime today, DateTime now, bool allowFuture) {
    if (mm < 1 || mm > 12) return SpokenDayResult(invalid: 'o mês $mm não existe', matched: matched);
    final stillAhead = mm > today.month || (mm == today.month && dd > today.day);
    var year = stillAhead ? now.year - 1 : now.year;
    if (stillAhead && allowFuture && dd >= 1 && dd <= _daysIn(year, mm) && today.difference(DateTime(year, mm, dd)).inDays > 62) {
      year = now.year;
    }
    if (dd < 1 || dd > _daysIn(year, mm)) {
      return SpokenDayResult(invalid: '${_monthNames[mm - 1]} não tem dia $dd', matched: matched);
    }
    final d = DateTime(year, mm, dd);
    return SpokenDayResult(day: _one(d, 'de ${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}', matched));
  }
}
