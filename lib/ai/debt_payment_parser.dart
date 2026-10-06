import 'local_nlp_engine.dart';

/// A detected "someone paid me back" phrase, e.g. "o João me pagou a dívida dele,
/// porém apenas 70 reais" -> personName: "João", amountPaid: 70.0.
class DebtPaymentMatch {
  final String personName;
  final double amountPaid;

  const DebtPaymentMatch({required this.personName, required this.amountPaid});
}

/// Detects and parses natural-language phrases where the user reports receiving a
/// payment (full or partial) against an existing debt/loan, e.g.:
/// - "o João me pagou a dívida dele, porém apenas 70 reais"
/// - "a Maria me devolveu 50 reais"
/// - "recebi 100 do Pedro"
/// - "o joão quitou o que devia"
///
/// This is intentionally separate from [LocalFinancialNlpEngine]'s loan-creation
/// detection ("emprestei X pro Fulano"): the two are opposite directions of the same
/// relationship (creating a debt vs. settling one) and are matched to an *existing*
/// reminder by name, not parsed into a fresh draft.
class DebtPaymentParser {
  // "de volta", "de novo", "de graça" are how it came, not from whom:
  // "recebi 7 de volta no uber" named nobody (CHAOS-A-024); "recebi 50 de
  // volta do joão" still names João.
  static const _recebiInfix = r'(?:[\d.,]+\s*(?:reais?|contos?|pilas?|r\$)?\s*)?(?:o\s+pagamento\s+)?(?:de\s+(?:volta|novo|gra[cç]a)\s+)?';
  static const _fromWhom = r'(?:de|do|da)\s+(?!(?:volta|novo|gra[cç]a)\b)';

  static final RegExp _paymentVerbPattern = RegExp(
    r'me\s+pagou|me\s+devolveu|me\s+quitou|'
    r'quitou\s+(?:a\s+)?(?:d[ií]vida|empr[eé]stimo|o\s+que\s+dev(?:ia|e))|'
    r'pagou\s+(?:a\s+)?(?:d[ií]vida|empr[eé]stimo|o\s+que\s+dev(?:ia|e))|'
    // "o joão pagou 50 do que me devia" (CONV-026).
    r'pagou\s+(?:r\$\s*)?[\d.,]+\s*(?:reais?|contos?)?\s+(?:do|da|de)\s+(?:o\s+)?(?:que\s+)?(?:me\s+)?(?:dev(?:ia|e)|d[ií]vida|empr[eé]stimo)|'
    r'recebi\s+' + _recebiInfix + _fromWhom,
    caseSensitive: false,
  );

  static final List<RegExp> _namePatterns = [
    RegExp(r'\b(?:o|a)\s+([a-zA-ZÀ-ÿ]+)\s+me\s+(?:pagou|devolveu|quitou)\b', caseSensitive: false),
    RegExp(r'\b(?:o|a)\s+([a-zA-ZÀ-ÿ]+)\s+(?:quitou|pagou)\s+(?:a\s+)?(?:d[ií]vida|empr[eé]stimo|o\s+que\s+dev(?:ia|e))\b', caseSensitive: false),
    RegExp(r'\b(?:o|a)\s+([a-zA-ZÀ-ÿ]+)\s+(?:me\s+)?pagou\s+(?:r\$\s*)?[\d.,]+', caseSensitive: false),
    RegExp(r'\brecebi\s+' + _recebiInfix + _fromWhom + r'([a-zA-ZÀ-ÿ]+)\b', caseSensitive: false),
    RegExp(r'\b([a-zA-ZÀ-ÿ]+)\s+me\s+(?:pagou|devolveu|quitou)\b', caseSensitive: false),
  ];

  // Includes common nouns that follow "recebi ... de/do/da" in ordinary income
  // statements ("recebi 3000 de salário") so they're never mistaken for a person's name.
  static const _stopWords = {
    'ele', 'ela', 'eles', 'elas', 'cara', 'mano', 'mina', 'pessoa', 'amigo', 'amiga',
    'cliente', 'menino', 'menina', 'cesar', 'césar',
    'salario', 'salário', 'reembolso', 'freela', 'trabalho', 'bonus', 'bônus',
    'presente', 'aluguel', 'dividendo', 'dividendos', 'proventos', 'pix', 'banco',
    'empresa', 'venda', 'vendas', 'comissao', 'comissão',
    // Possessives and people/sources of ordinary income: "recebi o pagamento
    // do meu salário", "o chefe me pagou 1500 do bico", "recebi 50 da minha
    // vó", "recebi 400 de diária" were answered "no debt in the name of Meu".
    'meu', 'minha', 'meus', 'minhas', 'seu', 'sua', 'nosso', 'nossa', 'um', 'uma',
    'chefe', 'patrao', 'patrão', 'patroa', 'firma', 'emprego', 'bico', 'diaria', 'diária', 'diarias', 'diárias',
    'hora', 'horas', 'extra', 'extras', 'governo', 'inss', 'fgts', 'restituicao', 'restituição', 'estorno',
    'reembolsaram', 'cashback', 'premio', 'prêmio', 'loja', 'app', 'aplicativo', 'mercado', 'uber', 'ifood',
  };

  /// What César says when the phrase sounded like a debt payment but nobody
  /// by that name owes anything — it is then recorded as ordinary income.
  static String _brl(double v) => 'R\$ ${v.toStringAsFixed(2).replaceAll('.', ',')}';

  /// What César says after applying a payment to a debt. A payment larger
  /// than the debt settles it and says what the extra was (CONV-036) — the
  /// whole amount received still goes to the balance.
  static String paymentReply(
    String personName, {
    required double paid,
    required double remaining,
    required bool fullyPaid,
    double excess = 0,
  }) {
    if (!fullyPaid) {
      return 'Anotado! $personName pagou ${_brl(paid)} da dívida. Restam ${_brl(remaining)} pendentes, que continuam na cobrança.';
    }
    if (excess > 0.009) {
      final owed = paid - excess;
      return 'Combinado! $personName quitou a dívida de ${_brl(owed)} e ainda sobraram ${_brl(excess)} a mais. '
          'Registrei os ${_brl(paid)} recebidos no seu saldo e encerrei a cobrança. '
          'Se esse excedente era outra coisa (um adiantamento, um presente), me diga que eu ajusto. 🎉';
    }
    return 'Combinado! $personName quitou a dívida com o pagamento de ${_brl(paid)}. Cobrança encerrada e o valor já entrou no seu saldo. 🎉';
  }

  static String noOpenDebtNote(String personName) =>
      'Não encontrei dívida em aberto no nome de $personName, então tratei como uma receita comum.';

  /// True when the phrase reports receiving money against an existing debt, as
  /// opposed to a fresh, unrelated income ("recebi 3000 de salário").
  static bool isDebtPaymentPhrase(String text) => _paymentVerbPattern.hasMatch(text.toLowerCase());

  /// Parses [text] into a [DebtPaymentMatch] when it both names a person and states an
  /// amount; returns null otherwise (ambiguous phrases are left for the caller to
  /// fall back to standard transaction parsing).
  static DebtPaymentMatch? parse(String text) {
    if (!isDebtPaymentPhrase(text)) return null;
    // "recebi 260 do joão e 9 da carla": two people, two values — one debt
    // payment would drop the other in silence (CHAOS-B-007). Left to the
    // batch reader instead.
    if (_severalPayers.hasMatch(text.toLowerCase())) return null;

    final name = _extractName(text);
    if (name == null) return null;

    final amount = _extractAmount(text);
    if (amount == null || amount <= 0) return null;

    return DebtPaymentMatch(personName: name, amountPaid: amount);
  }

  static final RegExp _severalPayers = RegExp(
    r'\d[\d.,]*\s*(?:reais?|contos?|pilas?)?\s+(?:de|do|da)\s+[a-zà-ú]+.*?(?:,|\be\b|\bmais\b)\s*(?:mais\s+)?(?:r\$\s*)?\d[\d.,]*\s*(?:reais?|contos?|pilas?)?\s+(?:de|do|da)\s+[a-zà-ú]+',
  );

  static String? _extractName(String text) {
    for (final pattern in _namePatterns) {
      final match = pattern.firstMatch(text);
      if (match == null) continue;
      final raw = match.group(1)?.trim();
      if (raw == null || raw.length < 2) continue;
      if (_stopWords.contains(raw.toLowerCase())) continue;
      return raw[0].toUpperCase() + raw.substring(1).toLowerCase();
    }
    return null;
  }

  static double? _extractAmount(String text) {
    final lower = text.toLowerCase();
    final patterns = [
      RegExp(r'r\$\s*(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)'),
      RegExp(r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d{1,3}(?:,\d{3})+(?:\.\d{1,2})?|\d+(?:[.,]\d{1,2})?)\s*(?:reais|real|conto|contos|pila|pilas)\b'),
      // Bare number fallback (e.g. "recebi 100 do Pedro" with no currency word).
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
