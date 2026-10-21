import 'category_name_matcher.dart';
import 'local_nlp_engine.dart';

/// "Quero juntar 5000 para uma viagem até dezembro" -> a new savings goal.
class GoalCreationMatch {
  final String title;
  final double targetAmount;
  final DateTime? targetDate;

  const GoalCreationMatch({required this.title, required this.targetAmount, this.targetDate});
}

/// "Guardei 100 na minha meta da viagem" -> a contribution toward an existing goal.
class GoalContributionMatch {
  final String goalTitle;
  final double amount;

  const GoalContributionMatch({required this.goalTitle, required this.amount});
}

/// Detects and parses natural-language phrases for creating a savings goal or
/// contributing to one, e.g.:
/// - "quero juntar 5000 para uma viagem até dezembro"
/// - "quero guardar 3000 pro notebook"
/// - "criar meta de 2000 para o curso até junho de 2026"
/// - "guardei 100 na minha meta da viagem" / "coloquei 50 na meta do notebook"
class GoalParser {
  static final RegExp _creationVerbPattern = RegExp(
    r'quero\s+(?:juntar|guardar|economizar|poupar)|'
    r'criar\s+(?:uma\s+)?meta|'
    r'meta\s+(?:nova\s+)?de\s+(?:r\$|\d)',
    caseSensitive: false,
  );

  static final RegExp _contributionVerbPattern = RegExp(
    r'(?:guardei|coloquei|depositei|economizei|poupei|juntei)\s+.*?\b(?:na|no)\s+(?:minha\s+)?meta\b',
    caseSensitive: false,
  );

  static const Map<String, int> _months = {
    'janeiro': 1, 'fevereiro': 2, 'março': 3, 'marco': 3, 'abril': 4, 'maio': 5, 'junho': 6,
    'julho': 7, 'agosto': 8, 'setembro': 9, 'outubro': 10, 'novembro': 11, 'dezembro': 12,
  };

  static bool isGoalCreationPhrase(String text) => _creationVerbPattern.hasMatch(text.toLowerCase());

  static bool isGoalContributionPhrase(String text) => _contributionVerbPattern.hasMatch(text.toLowerCase());

  static GoalCreationMatch? parseCreation(String text) {
    if (!isGoalCreationPhrase(text)) return null;

    final amount = _extractAmount(text);
    if (amount == null || amount <= 0) return null;

    final title = _extractGoalTitle(text);
    if (title == null || title.isEmpty) return null;

    return GoalCreationMatch(title: title, targetAmount: amount, targetDate: _extractTargetDate(text));
  }

  static GoalContributionMatch? parseContribution(String text) {
    if (!isGoalContributionPhrase(text)) return null;

    final amount = _extractAmount(text);
    if (amount == null || amount <= 0) return null;

    final lower = text.toLowerCase();
    final match = RegExp(r'\b(?:na|no)\s+(?:minha\s+)?meta\s*(?:d[aeo]\s+)?([a-zà-ÿ0-9\s]+)$', caseSensitive: false).firstMatch(lower);
    var title = match?.group(1)?.trim();
    if (title == null || title.isEmpty) return null;
    title = title.replaceAll(RegExp(r'[.!?]+$'), '').trim();

    return GoalContributionMatch(goalTitle: title, amount: amount);
  }

  static String? _extractGoalTitle(String text) {
    final lower = text.toLowerCase();
    // "... para/pro/pra uma viagem até dezembro" -> "viagem"
    // Notes: 'uma' must be tried before 'um' with a `\b` after the article, otherwise
    // 'um' alone matches as a prefix of 'uma' and leaves a stray 'a' glued to the
    // title. The stop word 'até' uses a lookahead instead of a trailing `\b`
    // because `\b` is ASCII-only and doesn't reliably border an accented 'é'.
    final match = RegExp(
      r'(?:para|pra|pro)\s+(?:uma|um|o|a)?\b\s*([a-zà-ÿ0-9\s]+?)(?:\s+at[ée](?=\s|$)|\s*$)',
      caseSensitive: false,
    ).firstMatch(lower);
    var title = match?.group(1)?.trim();
    if (title == null || title.isEmpty) return null;

    title = title.replaceAll(RegExp(r'[.!?]+$'), '').trim();
    // "pra comprar um celular" is the "Celular", "pra fazer uma viagem" the
    // "Viagem": the verb and its article aren't the name of the goal.
    title = title.replaceFirst(RegExp(r'^(?:comprar|trocar\s+(?:de|o|a)|pagar|fazer|ter|quitar|dar\s+entrada\s+(?:n[oa]|em))\s+(?:(?:uma|um|o|a|meu|minha)\s+)?'), '').trim();
    if (title.isEmpty) return null;
    return title[0].toUpperCase() + title.substring(1);
  }

  /// The deadline said in [text]: a month (with or without the year), "fim
  /// do ano", "ano que vem", "daqui a 6 meses". Null when none is said.
  static DateTime? targetDateIn(String text) {
    final lower = CategoryNameMatcher.foldAccents(text.toLowerCase());
    final later = RegExp(r'\b(?:daqui\s+a|em|dentro\s+de)\s+(\d{1,2})\s+(meses|mes|anos|ano)\b').firstMatch(lower);
    if (later != null) {
      final n = int.parse(later.group(1)!) * (later.group(2)!.startsWith('ano') ? 12 : 1);
      final now = DateTime.now();
      return DateTime(now.year, now.month + n, 28);
    }
    if (RegExp(r'\b(?:ano\s+que\s+vem|proximo\s+ano)\b').hasMatch(lower) && !RegExp(r'\b(?:janeiro|fevereiro|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)\b').hasMatch(lower)) {
      return DateTime(DateTime.now().year + 1, 12, 31);
    }
    return _extractTargetDate(lower);
  }

  static DateTime? _extractTargetDate(String text) {
    final lower = text.toLowerCase();

    if (RegExp(r'fim\s+do\s+ano|final\s+do\s+ano').hasMatch(lower)) {
      return DateTime(DateTime.now().year, 12, 31);
    }

    for (final entry in _months.entries) {
      if (!lower.contains(entry.key)) continue;
      final now = DateTime.now();
      var year = now.year;

      final yearMatch = RegExp('${entry.key}\\s+de\\s+(\\d{4})').firstMatch(lower);
      if (yearMatch != null) {
        year = int.parse(yearMatch.group(1)!);
      } else if (entry.value < now.month) {
        year += 1; // e.g. "até março" said in September means next March
      }
      return DateTime(year, entry.value, 28);
    }
    return null;
  }

  static double? _extractAmount(String text) {
    // "10 mil", "1,5 mil", "3k" (the 10 alone was the target: R$ 10).
    final lower = text.toLowerCase().replaceAllMapped(RegExp(r'(\d+(?:[.,]\d+)?)\s*(?:mil|k)\b'),
        (m) => '${(double.parse(m.group(1)!.replaceAll('.', '').replaceAll(',', '.')) * 1000).round()} reais');
    final patterns = [
      RegExp(r'r\$\s*(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)'),
      RegExp(r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)\s*(?:reais|real|conto|contos|pila|pilas)\b'),
      RegExp(r'\b(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)\b'),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(lower);
      if (match != null) {
        final value = LocalFinancialNlpEngine.cleanAndParseAmount(match.group(1));
        if (value != null && value > 0) return value;
      }
    }
    return null;
  }
}
