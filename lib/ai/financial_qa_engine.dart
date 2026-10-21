import '../backend/models/budget_category.dart';
import '../backend/models/financial_goal.dart';
import '../backend/models/financial_transaction.dart';
import '../backend/repositories/financial_repository.dart';
import 'cesar_text.dart';
import 'financial_report_rag_engine.dart';
import 'local_nlp_engine.dart';
import 'temporal_date_parser.dart';

/// What a question asks for. Each kind is answered from the repository.
enum QaKind {
  spending,
  income,
  largestExpense,
  smallestExpense,
  topCategory,
  balance,
  inTheRed,
  recent,
  dailyBudget,
  freeUntilIncome,
  goals,
  savings,
  search,
  budgetRemaining,
  comparison,
  count,
  lastTime,
  bills,
  debtors,
  overview,
}

/// A question reduced to its parts — kind + filter term + period — so a
/// follow-up ("e ontem?", "e com mercado?") can reuse it changing only what
/// the ellipsis changed. This is what lets César keep the thread of a
/// conversation about the data.
class QaQuery {
  final QaKind kind;

  /// Merchant, category or payment method filter ("uber", "saúde", "pix"); '' = none.
  final String term;

  /// Canonical period label ("hoje", "ontem", "anteontem", "esta semana",
  /// "semana passada", "este mês", "mês passado"), or null for the kind's default.
  final String? period;

  /// How many items a list/ranking should show.
  final int limit;

  /// Position in a ranking: "o segundo maior gasto" is rank 2.
  final int rank;

  /// Search filters ("acima de 100", "abaixo de 50", "no crédito",
  /// receitas instead of gastos) — see [QaKind.search].
  final double? minAmount;
  final double? maxAmount;
  final String? payment;
  final bool incomeOnly;

  const QaQuery(this.kind,
      {this.term = '', this.period, this.limit = 5, this.rank = 1, this.minAmount, this.maxAmount, this.payment, this.incomeOnly = false});

  QaQuery copyWith({QaKind? kind, String? term, String? period, int? limit, int? rank, double? minAmount, double? maxAmount, String? payment}) => QaQuery(
        kind ?? this.kind,
        term: term ?? this.term,
        period: period ?? this.period,
        limit: limit ?? this.limit,
        rank: rank ?? this.rank,
        minAmount: minAmount ?? this.minAmount,
        maxAmount: maxAmount ?? this.maxAmount,
        payment: payment ?? this.payment,
        incomeOnly: incomeOnly,
      );

  @override
  String toString() => 'QaQuery($kind, term="$term", period=$period)';
}

class QaAnswer {
  /// Chat text (markdown-ish, may have several lines).
  final String text;

  /// Short version for the voice.
  final String spokenText;
  final QaQuery query;
  final ReportChartData? chart;

  const QaAnswer({required this.text, required this.spokenText, required this.query, this.chart});

  /// Route name used by the QA batteries ("report:spending", "report:balance"...).
  String get route {
    switch (query.kind) {
      case QaKind.spending:
        return 'report:spending';
      case QaKind.balance:
      case QaKind.inTheRed:
      case QaKind.comparison:
      case QaKind.overview:
        return 'report:overview';
      case QaKind.bills:
        return 'report:bills';
      case QaKind.debtors:
        return 'report:debtors';
      default:
        return 'report:${query.kind.name}';
    }
  }
}

/// Answers questions about the user's own data — "qual meu maior gasto?",
/// "tô no vermelho?", "quanto recebi esse mês?", "quais foram meus últimos
/// lançamentos?", "quanto posso gastar por dia até o fim do mês?", "quanto
/// gastei no pix?" — 100% on-device, from the repository. Bills, debtors and
/// the overview reuse [FinancialReportRagEngine] (same report the chat already
/// showed); everything else is computed here.
///
/// Pure Dart: [now] can be injected so tests are deterministic.
class FinancialQaEngine {
  final FinancialRepository repository;
  final DateTime Function() _clock;

  FinancialQaEngine({required this.repository, DateTime Function()? now}) : _clock = now ?? DateTime.now;

  // ───────────────────────── parsing ─────────────────────────

  static const _periodPatterns = <String, String>{
    r'\bante\s*-?\s*ontem\b': 'anteontem',
    r'\bontem\b': 'ontem',
    r'\bhoje\b': 'hoje',
    r'\b(?:semana\s+passada|ultima\s+semana)\b': 'semana passada',
    r'\b(?:(?:es[st]a|n(?:es[st]a|essa))\s+semana|da\s+semana)\b': 'esta semana',
    r'\b(?:mes\s+passado|ultimo\s+mes)\b': 'mês passado',
    r'\b(?:(?:es[st]e|n(?:es[st]e|esse))\s+mes|do\s+mes|no\s+mes|mes\s+atual)\b': 'este mês',
  };

  /// "nos últimos 7 dias", "nas últimas 2 semanas", "últimos 3 meses".
  static final _lastN = RegExp(r'\b(?:(?:n|d)?(?:os|as)\s+)?ultim[oa]s\s+(\d{1,3}|dois|duas|tres|quatro|cinco|seis|sete|oito|nove|dez|quinze|vinte|trinta)\s+(dias|semanas|meses)\b');

  /// Canonical period named in [folded] text, or null.
  static String? periodIn(String folded) {
    final n = _lastN.firstMatch(folded);
    if (n != null) {
      final count = _numberWord(n.group(1)!);
      final unit = n.group(2)!;
      if (count == 1) return unit == 'dias' ? 'hoje' : (unit == 'semanas' ? 'esta semana' : 'este mês');
      return unit == 'semanas' ? 'nas últimas $count semanas' : 'nos últimos $count $unit';
    }
    for (final e in _periodPatterns.entries) {
      if (RegExp(e.key).hasMatch(folded)) return e.value;
    }
    return null;
  }

  static String _stripPeriods(String folded) {
    var s = folded.replaceAll(_lastN, ' ');
    for (final p in _periodPatterns.keys) {
      s = s.replaceAll(RegExp(p), ' ');
    }
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static const _fillers = r'(?:ate\s+agora|ate\s+hoje|no\s+total|ao\s+todo|por\s+enquanto|la|mesmo|ai|afinal|entao|cesar|muito|demais|tanto|bastante)';

  /// Cleans a filter term: drops periods, fillers and leading prepositions/articles.
  static String _cleanTerm(String raw) {
    var t = _stripPeriods(raw);
    t = t.replaceAll(RegExp('\\b$_fillers\\b'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    const lead = r'(?:com|de|do|da|dos|das|no|na|nos|nas|em|o|a|os|as|ao|aos|pelo|pela|pro|pra|para|meu|minha|meus|minhas|um|uma|eu|que)';
    for (var i = 0; i < 4; i++) {
      t = t.replaceFirst(RegExp('^$lead(?:\\s+|\$)'), '');
      t = t.replaceFirst(RegExp(r'(?:^|\s+)(?:e|de|do|da|no|na|em|com|o|a)$'), '');
    }
    return t.trim();
  }

  static final _questionStart = RegExp(
      r'^(?:quanto|quantos|quantas|qual|quais|quando|como|onde|o\s+que|oque|que|to|tou|estou|ta|sera|tenho|posso|quem|cade|'
      r'me\s+(?:mostra|diz|fala|conta|da|passa)|mostra|mostre|lista|liste|ver|veja|e\s+ai|faz|faca|fazer|manda|da\s+um|diz|fala)\b');

  /// An interrogative word anywhere ("o joão me deve quanto?", "sobrou
  /// quanto do salário?") — Portuguese puts it at the end too.
  static final _interrogative = RegExp(r'\b(?:quanto|quantos|quantas|qual|quais|quando|onde|quem|cade|por\s*que|sera\s+que)\b');

  static int _numberWord(String w) {
    const words = {'dois': 2, 'duas': 2, 'tres': 3, 'quatro': 4, 'cinco': 5, 'seis': 6, 'sete': 7, 'oito': 8, 'nove': 9, 'dez': 10, 'quinze': 15, 'vinte': 20, 'trinta': 30};
    return words[w] ?? int.tryParse(w) ?? 5;
  }

  static const _months = ['janeiro', 'fevereiro', 'marco', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
  static final _monthPattern = RegExp(r'\b(?:(?:em|de|no\s+mes\s+de|do\s+mes\s+de|mes\s+de|que\s+em|que\s+no\s+mes\s+de)\s+)?(' + _months.join('|') + r')\b');

  /// "em setembro", "de agosto" → the month's canonical label ("em setembro").
  static String? monthIn(String folded) {
    final m = _monthPattern.firstMatch(folded);
    return m == null ? null : 'em ${m.group(1)}';
  }

  // ── What the question measures (one family of words per measure) ──
  static final _debtWords = RegExp(r'\b(?:me\s+deve\w*|me\s+devendo|(?:alguem|quem|gente|pessoa)\s+(?:ainda\s+)?(?:ta\s+|esta\s+)?devendo|deve\s+(?:pra|para|a)\s+mim|me\s+pag(?:ou|ar|aram|a)|(?:a|pra)\s+receber|dividas?\s+(?:comigo|a\s+receber))\b');
  static final _comparisonWords = RegExp(r'\b(?:mais\s+ou\s+menos|compar\w*|em\s+relacao|(?:mais|menos)\s+(?:do\s+)?que\s+(?:em\s+|no\s+|o\s+|na\s+)?(?:mes|semana|' +
      _months.join('|') + r')|gastando\s+(?:demais|muito|mais)|exagerando|exagerei|to\s+gastando|'
          // "gastei mais esse mês ou no passado?"
          r'(?:esse|este|nesse|neste)\s+mes\s+ou\s+(?:no\s+|o\s+|do\s+|n[oa]\s+)?(?:mes\s+)?(?:passado|anterior)|ou\s+(?:no|o|do)\s+(?:mes\s+)?(?:passado|anterior))\b');
  static final _overviewWords = RegExp(r'\b(?:resumo|resumao|balanco|panorama|vida\s+financeira|situacao(?:\s+financeira)?|minhas\s+financas|as\s+financas|minhas\s+contas\s+no\s+geral|'
      r'como\s+(?:ta|esta|estao|tao|vai|vao|anda|andam)\s+(?:a\s+|as\s+|o\s+|os\s+)?(?:minha|minhas|meu|meus)\s+(?:vida|financas|grana|dinheiro|mes|orcamento))\b');
  static final _whereMoneyWent = RegExp(r'\bcade\s+(?:o\s+|meu\s+|a\s+|minha\s+)?(?:dinheiro|grana|salario)\b|\bonde\s+(?:(?:eu\s+)?(?:foi|foram|vai|esta\s+indo|ta\s+indo|anda)\s+(?:parar\s+)?(?:o\s+|meu\s+|a\s+|minha\s+)?(?:dinheiro|grana|salario)|(?:eu\s+)?(?:enfiei|meti|torrei|gastei)\s+(?:o\s+|meu\s+)?(?:dinheiro|grana|salario))\b');
  static final _balanceWords = RegExp(r'\b(?:saldo|sobrou|sobra|sobrando|resta|restou|me\s+resta|tenho\s+(?:na\s+conta|de\s+dinheiro|guardado|disponivel)|(?:quanto|qto)\s+(?:de\s+dinheiro\s+)?(?:eu\s+)?(?:(?:ainda|ja)\s+)?tenho)\b');
  static final _dailyWords = RegExp(r'\b(?:posso|consigo|da\s+pra|da\s+para|devo)\s+gastar\s+(?:hoje|por\s+dia|ao\s+dia|pro\s+dia|no\s+dia|cada\s+dia|diariamente|ate\s+o\s+(?:fim|final)\s+do\s+mes)\b|\b(?:orcamento|limite|gasto)\s+(?:diario|por\s+dia|de\s+hoje)\b|'
      // "quanto ainda posso gastar esse mês?", "quanto ainda dá pra gastar?"
      r'\bquanto\s+(?:eu\s+)?(?:ainda\s+)?(?:posso|consigo|da\s+pra|da\s+para)\s+gastar(?:\s+(?:esse|este|nesse|neste|no)\s+mes)?$');
  static final _countWords = RegExp(r'\b(?:quantas|quantos)\s+(?:vezes\s+)?(?!reais\b|real\b|conto\w*\b)');
  static final _lastTimeWords = RegExp(r'\b(?:ultima\s+vez|quando\s+(?:foi\s+(?:a\s+)?ultima|(?:eu\s+)?(?:foi\s+que\s+)?(?:paguei|gastei|fui|comprei|pedi|abasteci|recebi|usei|peguei|ganhei)))\b');
  static final _incomeWords = RegExp(r'\b(?:ganhei|ganho|ganhamos|recebi|recebo|recebemos|entrou|entraram|entrada|entradas|receita|receitas|faturei|faturamento|caiu|cairam|renda)\b');
  static final _spendingWords = RegExp(r'\b(?:gastei|gasto|gastos|gastamos|gastando|despesa|despesas|saiu|sairam|saida|saidas|paguei|pago|pagando|pagamos|torrei|torrando|desembolsei|custou|custa|custando|foi\s+gasto|quanto\s+(?:foi|deu|ficou)|total\s+de|'
      // "quanto já foi embora esse mês?", "quanto voou de grana?"
      r'(?:foi|foram|vai|ta\s+indo)\s+embora|voou|voaram|sumiu|sumiram)\b');

  /// Words that never name a filter: interrogatives, auxiliaries, the
  /// measure words themselves and fillers ("pela última vez", "de dinheiro").
  static final _emptyWords = RegExp(r'\b(?:quanto|quantos|quantas|qual|quais|quando|onde|como|que|o\s+que|oque|quem|cade|sera|foi|foram|e|eh|era|eu|ja|ainda|so|to|tou|estou|ta|tava|estava|tenho|tive|fiz|fui|'
      r'me|mim|pra\s+mim|meu|minha|meus|minhas|o|a|os|as|ao|aos|um|uma|uns|umas|de|do|da|dos|das|no|na|nos|nas|em|com|pro|pra|para|pelo|pela|por|'
      r'embora|voou|voaram|sumiu|sumiram|'
      r'diz|diga|fala|mostra|mostre|lista|liste|conta|manda|faz|faca|passa|total|valor|ao\s+todo|no\s+total|ate\s+agora|ate\s+hoje|por\s+enquanto|afinal|entao|cesar|la|ai|mesmo|'
      r'ultima\s+vez|pela\s+ultima\s+vez|vez|vezes|dinheiro|grana|lancamentos?|registros?|transac\w+|movimentac\w+|'
      r'gastei|gasto|gastos|gastamos|gastando|despesas?|saiu|sairam|saidas?|paguei|pago|pagando|pagamos|torrei|torrando|desembolsei|custou|custa|custando|deu|ficou|'
      r'ganhei|ganho|ganhamos|recebi|recebo|recebemos|entrou|entraram|entradas?|receitas?|faturei|faturamento|caiu|cairam|renda|'
      r'usei|peguei|pedi|comprei|abasteci|chamei|almocei|jantei|fui|fiz|tive|agora|mes|semana|hoje|ontem|anteontem)\b');

  static const _bigWords = r'maior(?:es)?|mais\s+(?:car|salgad|pesad|alt)[oa]s?';
  static const _smallWords = r'menor(?:es)?|mais\s+barat[oa]s?';
  static final _extremeLead = RegExp('\\b((?:(?:segund|terceir|quart|quint)[oa]\\s+)?(?:$_bigWords|$_smallWords))\\s+(?:gastos?|despesas?|compras?|lancamentos?|saidas?)\\b');
  static final _extremeTail = RegExp('\\b(?:gastos?|despesas?|compras?)\\s+(?:mais\\s+)?($_bigWords|$_smallWords|(?:segund|terceir|quart|quint)[oa]\\s+(?:maior|menor))\\b');

  static const _value = r'(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)(\s*mil)?';
  static final _minFilter = RegExp(r'\b(?:acima\s+de|mais\s+de|maior(?:es)?\s+(?:que|do\s+que|de)|superior(?:es)?\s+a|a\s+partir\s+de|pelo\s+menos|no\s+minimo)\s+(?:r\$\s*)?' + _value);
  static final _maxFilter = RegExp(r'\b(?:abaixo\s+de|menos\s+de|menor(?:es)?\s+(?:que|do\s+que|de)|inferior(?:es)?\s+a|ate|no\s+maximo)\s+(?:r\$\s*)?' + _value + r'(?!\s*(?:dias?|semanas?|mes|meses|anos?|horas?)\b)');
  static final _betweenFilter = RegExp(r'\bentre\s+(?:r\$\s*)?' + _value + r'\s+e\s+(?:r\$\s*)?' + _value);
  static final _paymentFilter = RegExp(r'\b(?:no|na|pelo|pela|em|via|com\s+o|com\s+a|usando\s+o)\s+(pix|cartao\s+de\s+credito|credito|cartao\s+de\s+debito|debito|dinheiro|especie|boleto)\b');
  static final _listing = RegExp(r'^(?:me\s+)?(?:mostra|mostre|lista|liste|exibe|exiba|filtra|filtre|procura|procure|busca|busque|ve|veja|ver)\b|'
      r'\bquais\s+(?:foram\s+|sao\s+)?(?:os\s+|as\s+|meus\s+|minhas\s+)?(?:gastos|compras|lancamentos|despesas|pagamentos|transacoes|receitas|entradas)\b|'
      r'^(?:e\s+)?(?:o\s+)?que\s+(?:eu\s+)?(?:comprei|paguei)\b');

  static double _filterValue(String digits, String? thousand) {
    final v = LocalFinancialNlpEngine.cleanAndParseAmount(digits) ?? 0;
    return thousand != null && thousand.trim().isNotEmpty ? v * 1000 : v;
  }

  /// [s] as a search, when it filters by value, or lists with a payment
  /// method or a name. Null otherwise.
  static QaQuery? _searchQuery(String s, String? period) {
    final min = _minFilter.firstMatch(s), max = _maxFilter.firstMatch(s), between = _betweenFilter.firstMatch(s);
    final pay = _paymentFilter.firstMatch(s);
    final listing = _listing.hasMatch(s);
    var rest = s;
    for (final m in [min, max, between, pay]) {
      if (m != null) rest = rest.replaceFirst(m.group(0)!, ' ');
    }
    rest = rest
        .replaceAll(_listing, ' ')
        // ("os últimos 2 lançamentos" is the recent list, not a search for "últimos 2".)
        .replaceAll(RegExp(r'\bultim[oa]s?(?:\s+(?:\d+|dois|duas|tres|cinco|dez))?\b'), ' ')
        .replaceAll(RegExp(r'\b(?:todos|todas|tudo|lancamentos?|compras?|pagamentos?|transacoes|fiz|feitas?|feitos?|eu|meus|minhas|desde\s+sempre|de\s+sempre|desde\s+o\s+inicio)\b'), ' ');
    final term = _termOf(rest);
    final hasValueFilter = min != null || max != null || between != null;
    if (!hasValueFilter && !(listing && (pay != null || term.isNotEmpty))) return null;
    // A value filter needs a question or a listing: "gastei mais de 100 no mercado" is an entry.
    if (!listing && !RegExp(r'\b(?:quais|qual|quantos|quantas|quanto|mostra|lista|tem|teve|houve)\b').hasMatch(s)) return null;
    final income = RegExp(r'\b(?:receitas?|entradas?|recebi|ganhei|recebimentos?)\b').hasMatch(s);
    final always = RegExp(r'\b(?:desde\s+sempre|de\s+sempre|desde\s+o\s+inicio|de\s+todos\s+os\s+tempos)\b').hasMatch(s);
    return QaQuery(
      QaKind.search,
      term: term,
      period: always ? 'sempre' : period,
      minAmount: between != null ? _filterValue(between.group(1)!, between.group(2)) : (min == null ? null : _filterValue(min.group(1)!, min.group(2))),
      maxAmount: between != null ? _filterValue(between.group(3)!, between.group(4)) : (max == null ? null : _filterValue(max.group(1)!, max.group(2))),
      payment: pay == null ? null : _paymentCode(pay.group(1)!.replaceFirst(RegExp(r'^cartao\s+de\s+'), '')),
      incomeOnly: income,
      limit: 10,
    );
  }

  /// "segundo maior" → 2; anything else → 1.
  static int _rankOf(String w) =>
      const {'segund': 2, 'terceir': 3, 'quart': 4, 'quint': 5}[RegExp(r'(segund|terceir|quart|quint)').firstMatch(w)?.group(1)] ?? 1;

  /// The filter left after removing everything that isn't one.
  static String _termOf(String folded) {
    var t = _stripPeriods(folded);
    t = t.replaceAll(_monthPattern, ' ');
    // "de dinheiro" as payment is "em dinheiro"/"em espécie"; kept below.
    // ("no dinheiro vivo" is cash, not the Vivo operator.)
    final cashWords = RegExp(r'\b(?:em|no|de|com)\s+(?:especie|dinheiro\s+vivo|dinheirinho)\b|\b(?:em|no|com\s+o)\s+dinheiro\b');
    final cash = cashWords.hasMatch(t);
    if (cash) t = t.replaceAll(cashWords, ' ');
    t = t.replaceAllMapped(RegExp(r'\bcartao\s+de\s+(credito|debito)\b'), (m) => m.group(1)!);
    for (var i = 0; i < 3; i++) {
      t = t.replaceAll(_emptyWords, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    if (cash && t.isEmpty) return 'dinheiro';
    return _cleanTerm(t);
  }

  /// Turns a question into a [QaQuery], or null when [text] isn't a question
  /// this engine answers. Statements ("gastei 50 no mercado") never match.
  ///
  /// Structure, not phrases: a question is **what it measures** (spending,
  /// income, balance, count, last time, debt, summary, comparison) ×
  /// **filter** (category/term, payment method, person) × **period** (today,
  /// yesterday, this/last week, this/last month, a month by name). Each part
  /// is read from its own family of words, wherever it is in the sentence.
  static QaQuery? parse(String text) {
    final s = CesarText.simplify(text);
    if (s.isEmpty) return null;
    final hasDigit = RegExp(r'\d').hasMatch(s);
    // "gastei 42 na padaria no pix?": an entry (with a doubt) — a past entry
    // verb with a value and no interrogative word is not a question.
    if (hasDigit && !_interrogative.hasMatch(s) &&
        RegExp(r'^(?:\w+\s+){0,3}(?:gastei|paguei|comprei|recebi|ganhei|transferi|torrei|abasteci|depositei|mandei)\b').hasMatch(s)) {
      return null;
    }
    final isQuestion = text.trim().endsWith('?') || _questionStart.hasMatch(s) || (_interrogative.hasMatch(s) && !hasDigit);
    final month = monthIn(s);
    final period = periodIn(s) ?? month;

    // These two are asked without a question mark too ("tô no vermelho",
    // "gastei mais que mês passado") — but never with an amount, which is a
    // statement to record ("fiquei no vermelho depois de gastar 500...").
    if (!hasDigit && RegExp(r'\b(?:(?:to|tou|estou|esteja|ta|fiquei|fico|esta|tamo|estamos|vou\s+ficar)\s+(?:no\s+)?(?:vermelho|negativo|negativad[oa])|saldo\s+(?:esta\s+|ta\s+)?negativo|no\s+vermelho)\b')
        .hasMatch(s)) {
      return const QaQuery(QaKind.inTheRed);
    }
    if (!hasDigit && _comparisonWords.hasMatch(s) && (isQuestion || RegExp(r'\b(?:mais|menos)\s+(?:do\s+)?que\b').hasMatch(s))) {
      // "gastei mais ou menos que em agosto?": this month against the month
      // named (or the one before).
      final versus = month ?? (RegExp(r'\bsemana\b').hasMatch(s) ? 'semana passada' : 'mês passado');
      // "tô gastando mais com ifood que no mês passado?": the comparison of one thing.
      final about = RegExp(r'\b(?:com|de|no|na|em)\s+([a-z]+(?:\s+[a-z]+)?)\s+(?:do\s+)?(?:que|quanto|comparado|em\s+relacao)\b')
          .firstMatch(_stripPeriods(s).replaceAll(_monthPattern, ' ').replaceAll(RegExp(r'\s+'), ' '))
          ?.group(1);
      final term = about == null ? '' : _cleanTerm(about);
      return QaQuery(QaKind.comparison, period: versus, term: RegExp(r'^(?:mes|semana|antes|passado|gasto|gastos)$').hasMatch(term) ? '' : term);
    }

    if (!isQuestion && !RegExp(r'^(?:meu|o\s+meu)\s+saldo$|^saldo$|^extrato$|^meu\s+extrato$').hasMatch(s)) {
      return null;
    }

    // Money free until the next income: "tenho quanto livre até o salário?".
    if (RegExp(r'\blivre\s+ate\s+(?:o\s+|a\s+)?(?:salario|pagamento|proxim[oa]\s+\w+|dia\s+\d+|virada)|'
            r'ate\s+(?:o\s+)?(?:proximo\s+)?salario\s+(?:cair|entrar)|(?:sobra|resta)\s+ate\s+o\s+(?:proximo\s+)?salario')
        .hasMatch(s)) {
      return const QaQuery(QaKind.freeUntilIncome);
    }
    if (_dailyWords.hasMatch(s)) return const QaQuery(QaKind.dailyBudget);

    // Budget left in a category: "quanto ainda posso gastar com lazer?".
    final budgetQ = RegExp(r'(?:posso|consigo|da\s+pra|da\s+para)\s+gastar\s+(?:com|de|em|no|na)\s+(.+)$').firstMatch(s) ??
        RegExp(r'como\s+(?:esta|ta)\s+(?:o\s+|meu\s+)?(?:orcamento|limite)\s+(?:de|do|da|com)\s+(.+)$').firstMatch(s) ??
        RegExp(r'quanto\s+(?:falta|resta|sobra)\s+(?:no|do)\s+(?:orcamento|limite)\s+(?:de|do|da)\s+(.+)$').firstMatch(s);
    if (budgetQ != null) {
      final term = _cleanTerm(budgetQ.group(1)!);
      if (term.isNotEmpty) return QaQuery(QaKind.budgetRemaining, term: term);
    }

    // The budgets as a whole: "estou dentro do orçamento?", "estourei algum
    // limite?" (one category was asked above).
    if (RegExp(r'\b(?:dentro|fora)\s+do\s+(?:meu\s+)?(?:orcamento|limite)s?\b|\bestour(?:ei|ou|ando|aram)\s+(?:o\s+|algum\s+|meu\s+|os\s+|meus\s+)?(?:orcamento|limite)s?\b|'
            r'\bcomo\s+(?:esta|ta|estao|tao|vai|vao)\s+(?:o\s+|os\s+|meu\s+|meus\s+)?(?:orcamentos?|limites?)$|\bpassei\s+(?:de\s+|do\s+)?(?:algum\s+)?(?:orcamento|limite)\b')
        .hasMatch(s)) {
      return const QaQuery(QaKind.budgetRemaining);
    }

    // "quanto eu economizei esse mês?": what was left between income and
    // spending — not a goal (unless one is named: "guardei pra viagem").
    if (RegExp(r'\bquanto\s+(?:eu\s+)?(?:ja\s+)?(?:economizei|poupei|consegui\s+(?:economizar|guardar|poupar)|guardei)\b').hasMatch(s) &&
        !RegExp(r'\b(?:metas?|pra|para|pro|na\s+meta|no\s+cofrinho)\b').hasMatch(s)) {
      return QaQuery(QaKind.savings, period: period);
    }

    // Goals.
    if (RegExp(r'\bmetas?\b').hasMatch(s) ||
        RegExp(r'quanto\s+(?:eu\s+)?(?:ja\s+)?(?:guardei|juntei|economizei|poupei)|\b(?:tenho|tem)\s+(?:guardado|juntado|economizado|poupado)\b').hasMatch(s)) {
      final m = RegExp(r'\bmetas?\s+(?:d[aeo]s?\s+)?(.+)$').firstMatch(s) ??
          RegExp(r'(?:guardei|juntei|economizei|poupei|guardado|juntado|economizado|poupado)\s+(?:pra|para|pro|na|no)\s+(?:a\s+|o\s+)?(.+)$').firstMatch(s);
      return QaQuery(QaKind.goals, term: m == null ? '' : _cleanTerm(m.group(1)!));
    }

    // Debts to the user, optionally of one person ("o joão me deve quanto?").
    if (_debtWords.hasMatch(s) || FinancialReportRagEngine.isReportQuery(text) && RegExp(r'dev').hasMatch(s)) {
      final person = RegExp(r'^(?:e\s+)?(?:(?:quanto|qto)\s+)?(?:(?:o|a|que\s+o|que\s+a)\s+)?([a-z]{3,})\s+(?:ainda\s+|ja\s+)?(?:me\s+deve|ta\s+me\s+devendo|esta\s+me\s+devendo|me\s+pagou|deve\s+pra\s+mim)')
          .firstMatch(s)
          ?.group(1);
      const notNames = {'alguem', 'quem', 'quanto', 'gente', 'pessoal', 'ninguem', 'galera', 'eles', 'elas', 'voce'};
      return QaQuery(QaKind.debtors, term: person == null || notNames.contains(person) ? '' : person);
    }

    // A search with filters: "mostra os gastos acima de 100 no crédito",
    // "quais compras eu fiz no ifood em setembro?", "o que eu paguei no pix
    // essa semana?" (before the rankings: "gastos maiores que 200" is a filter).
    final search = _searchQuery(s, period);
    if (search != null) return search;

    // Largest / smallest expense ("o mais salgado", "o segundo maior").
    final extreme = _extremeLead.firstMatch(s) ?? _extremeTail.firstMatch(s);
    if (extreme != null) {
      final w = extreme.group(1)!;
      final smallest = w.contains('menor') || w.contains('barat');
      final plural = w.endsWith('es') || w.endsWith('os') || w.endsWith('as');
      final rank = _rankOf(w);
      final n = RegExp(r'\b(\d+|dois|duas|tres|cinco|dez)\s+(?:maiores|menores)').firstMatch(s);
      return QaQuery(smallest ? QaKind.smallestExpense : QaKind.largestExpense,
          period: period, limit: rank > 1 ? 1 : (n != null ? _numberWord(n.group(1)!) : (plural ? 3 : 1)), rank: rank);
    }

    // Category ranking: "com o que eu mais gastei?", "onde foi parar meu
    // dinheiro?", "qual categoria tá pesando mais?".
    if ((RegExp(r'(?:mais\s+gast\w*|gast\w*\s+mais|(?:pesando|pesa|pesou|pesam|levando|leva|levou|consome|come|comendo)\s+mais|mais\s+pesad[oa])').hasMatch(s) &&
            RegExp(r'\b(?:categoria|categorias|onde|com\s+o\s+que|com\s+que|em\s+que|no\s+que|qual|quais|o\s+que)\b').hasMatch(s)) ||
        RegExp(r'\bo\s+que\s+(?:mais\s+)?(?:pesa|pesou|esta\s+pesando|ta\s+pesando)\b').hasMatch(s) ||
        _whereMoneyWent.hasMatch(s)) {
      return QaQuery(QaKind.topCategory, period: period);
    }

    // Recent list.
    final recent = RegExp(r'\b(?:ultim[oa]s?)\s+(?:(\d+|dois|duas|tres|cinco|dez)\s+)?(?:lancamentos?|gastos?|transac\w+|despesas?|compras?|movimentac\w+|registros?|receitas?|entradas?)\b').firstMatch(s);
    if (recent != null ||
        RegExp(r'(?:mostra|mostre|lista|liste|ver|veja|quais\s+(?:sao|foram)|me\s+mostra)\s+(?:os\s+|as\s+)?(?:meus\s+|minhas\s+)?(?:lancamentos|gastos|transac\w+|despesas|compras|movimentac\w+|registros)$').hasMatch(s) ||
        RegExp(r'(?:mostra|mostre|lista|liste|ver|veja|quais\s+(?:sao|foram)|me\s+mostra)\s+(?:os\s+|as\s+)?(?:meus\s+|minhas\s+)?(?:lancamentos|transac\w+|movimentac\w+|registros)').hasMatch(s) ||
        RegExp(r'\bextrato\b').hasMatch(s) ||
        RegExp(r'^o\s+que\s+(?:eu\s+)?(?:gastei|lancei|registrei|comprei|paguei)\b').hasMatch(s)) {
      final n = recent?.group(1);
      final incomeOnly = RegExp(r'\b(?:receitas?|entradas?)\b').hasMatch(s);
      return QaQuery(QaKind.recent, period: period, limit: n != null ? _numberWord(n) : 5, term: incomeOnly ? 'receitas' : '');
    }

    // Bills.
    if (RegExp(r'(?:tenho|tem|ha|existe)\s+(?:alguma\s+|algum\s+)?(?:conta|contas|boleto|boletos)\s+(?:vencendo|pra\s+vencer|para\s+vencer|a\s+vencer|pra\s+pagar|para\s+pagar|atrasad\w*|em\s+aberto)|'
            r'o\s+que\s+(?:vence|tenho\s+pra\s+pagar)|(?:quais|que)\s+(?:contas|boletos)\s+(?:tenho|vencem|faltam)')
        .hasMatch(s)) {
      return QaQuery(QaKind.bills, period: period);
    }

    if (_overviewWords.hasMatch(s)) return QaQuery(QaKind.overview, period: period);
    if (_balanceWords.hasMatch(s) && !_spendingWords.hasMatch(s) && !RegExp(r'\b(?:ganhei|recebi|entrou)\b').hasMatch(s)) {
      return const QaQuery(QaKind.balance);
    }

    // Count: "quantas vezes eu pedi ifood?", "quantas corridas de uber eu fiz?".
    final count = _countWords.firstMatch(s);
    if (count != null) {
      var rest = s.substring(count.end);
      // "quantas corridas de uber": the complement names the filter.
      final complement = RegExp(r'^[a-z]+\s+(?:de|do|da|no|na|com)\s+(.+)$').firstMatch(rest);
      if (complement != null && !RegExp(r'^vezes\b').hasMatch(rest)) rest = complement.group(1)!;
      final term = _termOf(rest);
      if (term.isNotEmpty) return QaQuery(QaKind.count, term: term, period: period);
    }

    if (_lastTimeWords.hasMatch(s)) {
      final term = _termOf(s);
      if (term.isNotEmpty) return QaQuery(QaKind.lastTime, term: term);
    }

    // Spending or income, with a filter and a period.
    final spends = _spendingWords.hasMatch(s);
    final earns = _incomeWords.hasMatch(s);
    if (spends || earns) {
      // "quanto entrou de dinheiro": money in general, not cash.
      final term = _termOf(s);
      final kind = earns && !RegExp(r'\b(?:gastei|gasto|gastos|despesas?|paguei|pagando|torrei)\b').hasMatch(s) ? QaKind.income : QaKind.spending;
      return QaQuery(kind, term: term, period: period);
    }
    if (RegExp(r'^(?:quanto|qto)\s+(?:foi|deu|custou|custa|ficou)\b').hasMatch(s)) {
      return QaQuery(QaKind.spending, term: _termOf(s), period: period);
    }
    return null;
  }

  /// The measure a short follow-up switches to ("e o que entrou?" after a
  /// spending question), or null when it only changes the filter/period.
  static QaKind? _measureSwitch(String s) {
    if (_incomeWords.hasMatch(s) && !_spendingWords.hasMatch(s)) return QaKind.income;
    if (_spendingWords.hasMatch(s) && !_incomeWords.hasMatch(s)) return QaKind.spending;
    if (_balanceWords.hasMatch(s)) return QaKind.balance;
    return null;
  }

  /// A follow-up that reuses [previous] changing only what it names:
  /// "e ontem?", "e no mês passado?", "e com mercado?", "e em transporte?",
  /// "e o que entrou?".
  /// Returns null when [text] isn't an elliptical follow-up.
  static QaQuery? parseFollowUp(String text, QaQuery previous) {
    final s = CesarText.simplify(text);
    final m = RegExp(r'^(?:mas\s+)?e\s+(?:quanto\s+a\s+|sobre\s+|pra\s+|para\s+)?(.+)$').firstMatch(s);
    if (m == null) return null;
    final rest = m.group(1)!;
    if (rest.split(' ').length > 6) return null;
    // A search refined: "e no débito?", "e acima de 200?", "e em setembro?".
    if (previous.kind == QaKind.search) {
      final next = _searchQuery('mostra $rest', null);
      final period = periodIn(rest) ?? monthIn(rest);
      if (next != null || period != null) {
        return QaQuery(QaKind.search,
            term: next != null && next.term.isNotEmpty ? next.term : previous.term,
            period: period ?? previous.period,
            minAmount: next?.minAmount ?? previous.minAmount,
            maxAmount: next?.maxAmount ?? previous.maxAmount,
            payment: next?.payment ?? previous.payment,
            incomeOnly: previous.incomeOnly,
            limit: previous.limit);
      }
    }
    // A number isn't a filter ("e 30 na padaria" is a new expense).
    if (RegExp(r'\d').hasMatch(rest)) return null;
    // "e o menor?", "e o segundo maior?", "e o segundo?": the other end (or
    // the next place) of a ranking, with the same period and filter.
    final ext = RegExp('^(?:o\\s+|a\\s+)?((?:(?:segund|terceir|quart|quint)[oa]\\s+)?(?:$_bigWords|$_smallWords))(?:\\s+(?:gasto|despesa|compra))?\$')
        .firstMatch(rest);
    if (ext != null) {
      final w = ext.group(1)!;
      final small = w.contains('menor') || w.contains('barat');
      return QaQuery(small ? QaKind.smallestExpense : QaKind.largestExpense, term: previous.term, period: previous.period, rank: _rankOf(w), limit: 1);
    }
    // "quanto falta pra meta da viagem?" ⏎ "e quanto já tenho?": the same goal.
    if (previous.kind == QaKind.goals && RegExp(r'^(?:quanto\s+)?(?:eu\s+)?(?:ja\s+|ainda\s+)?(?:tenho|guardei|juntei|falta|faltam|economizei)\b').hasMatch(rest)) {
      return previous;
    }
    final nth = RegExp(r'^(?:o\s+|a\s+)?(segund|terceir|quart|quint)[oa](?:\s+(?:gasto|lugar|colocado))?$').firstMatch(rest);
    if (nth != null && (previous.kind == QaKind.largestExpense || previous.kind == QaKind.smallestExpense)) {
      return previous.copyWith(rank: _rankOf(nth.group(1)!), limit: 1);
    }
    final period = periodIn(rest) ?? monthIn(rest);
    final switched = _measureSwitch(rest);
    if (switched != null && switched != previous.kind) {
      return QaQuery(switched, term: _termOf(rest), period: period ?? previous.period, limit: previous.limit);
    }
    // A full question after "e" ("e quanto recebi?") is parsed on its own.
    if (parse(rest) != null && !RegExp(r'^(?:no|na|em|com|de|do|da|o|a|hoje|ontem|anteontem|esta|essa|nesta|nessa|semana|mes)\b').hasMatch(rest)) {
      return null;
    }
    final term = _termOf(rest);
    if (period == null && term.isEmpty) return null;

    var kind = previous.kind;
    const termKinds = {QaKind.spending, QaKind.income, QaKind.count, QaKind.lastTime, QaKind.budgetRemaining, QaKind.goals};
    if (term.isNotEmpty && !termKinds.contains(kind)) kind = QaKind.spending;
    return QaQuery(kind, term: term.isNotEmpty ? term : previous.term, period: period ?? previous.period, limit: previous.limit);
  }

  // ───────────────────────── answering ─────────────────────────

  QaAnswer? answer(String text) {
    // "me mostra um gráfico dos meus gastos": the RAG report draws it.
    if (FinancialReportRagEngine.wantsChart(text) && FinancialReportRagEngine.isReportQuery(text)) {
      return _ragAnswer(text);
    }
    final q = parse(text);
    if (q != null) return answerQuery(q, originalText: text);
    // Everything the report engine already understood still works.
    if (FinancialReportRagEngine.isReportQuery(text)) return _ragAnswer(text);
    return null;
  }

  QaAnswer _ragAnswer(String text) {
    final rag = FinancialReportRagEngine(repository: repository);
    final result = rag.generateReport(text);
    final kind = switch (result.intent) {
      ReportIntent.debtors => QaKind.debtors,
      ReportIntent.bills => QaKind.bills,
      ReportIntent.spending => QaKind.spending,
      _ => QaKind.overview,
    };
    return QaAnswer(text: result.formattedText, spokenText: result.spokenText, query: QaQuery(kind), chart: result.chart);
  }

  QaAnswer answerQuery(QaQuery q, {String? originalText}) {
    switch (q.kind) {
      case QaKind.spending:
        return _spending(q, originalText);
      case QaKind.income:
        return _income(q);
      case QaKind.largestExpense:
      case QaKind.smallestExpense:
        return _extreme(q);
      case QaKind.topCategory:
        return _topCategory(q);
      case QaKind.balance:
        return _balance(q);
      case QaKind.inTheRed:
        return _inTheRed(q);
      case QaKind.recent:
        return _recent(q);
      case QaKind.dailyBudget:
        return _dailyBudget(q);
      case QaKind.goals:
        return _goals(q);
      case QaKind.savings:
        return _savings(q);
      case QaKind.search:
        return _search(q, originalText);
      case QaKind.freeUntilIncome:
        return _freeUntilIncome(q);
      case QaKind.budgetRemaining:
        return _budgetRemaining(q);
      case QaKind.comparison:
        return _comparison(q);
      case QaKind.count:
        return _count(q);
      case QaKind.lastTime:
        return _lastTime(q);
      case QaKind.debtors:
        return _debtors(q);
      case QaKind.bills:
      case QaKind.overview:
        return _viaRag(q, originalText);
    }
  }

  /// Who owes the user, or how much one person owes ("o joão me deve quanto?").
  QaAnswer _debtors(QaQuery q) {
    if (q.term.isNotEmpty) {
      final found = repository.findDebtorsByName(q.term);
      final name = q.term[0].toUpperCase() + q.term.substring(1);
      if (found.isEmpty) {
        final text = 'Não tenho nada anotado de $name te devendo. Se emprestou, diga por exemplo "emprestei 100 pro $name".';
        return QaAnswer(text: text, spokenText: text, query: q);
      }
      final total = found.fold(0.0, (a, d) => a + (d.amount ?? 0));
      final who = found.first.personName ?? name;
      final text = '🤝 $who te deve ${CesarText.money(total)}${found.length > 1 ? ' (${found.length} cobranças)' : ''}.';
      return QaAnswer(text: text, spokenText: text.replaceAll('🤝 ', ''), query: q);
    }
    final rag = FinancialReportRagEngine(repository: repository).generateReport('quem me deve');
    return QaAnswer(text: rag.formattedText, spokenText: rag.spokenText, query: q, chart: rag.chart);
  }

  DateRangeResult _range(String? period, {String fallback = 'este mês'}) {
    final label = period ?? fallback;
    final now = _clock();
    if (label.startsWith('em ')) {
      // A month by name: the most recent one (asking in March about
      // "dezembro" means last December).
      final idx = _months.indexOf(label.substring(3));
      if (idx >= 0) {
        final m = idx + 1;
        final year = m > now.month ? now.year - 1 : now.year;
        return DateRangeResult(
            start: DateTime(year, m, 1), end: DateTime(year, m + 1, 0, 23, 59, 59), label: label.replaceAll('marco', 'março'), matchedExpression: label);
      }
    }
    if (label == 'anteontem') {
      final d = CesarText.dayOnly(now).subtract(const Duration(days: 2));
      return DateRangeResult(start: d, end: DateTime(d.year, d.month, d.day, 23, 59, 59), label: 'anteontem', matchedExpression: 'anteontem');
    }
    // "nos últimos 7 dias": today and the 6 days before it.
    final lastN = RegExp(r'^n[oa]s\s+últim[oa]s\s+(\d+)\s+(dias|semanas|meses)$').firstMatch(label);
    if (lastN != null) {
      final n = int.parse(lastN.group(1)!);
      final today = CesarText.dayOnly(now);
      final start = switch (lastN.group(2)) {
        'dias' => today.subtract(Duration(days: n - 1)),
        'semanas' => today.subtract(Duration(days: n * 7 - 1)),
        _ => DateTime(today.year, today.month - n, today.day + 1),
      };
      return DateRangeResult(start: start, end: DateTime(today.year, today.month, today.day, 23, 59, 59), label: label, matchedExpression: label);
    }
    return TemporalDateParser.parse(label, referenceDate: now) ?? TemporalDateParser.parse('este mês', referenceDate: now)!;
  }

  /// "no mês passado", "ontem", "esta semana"... as it reads after a verb.
  static String _periodPhrase(String label) {
    switch (label) {
      case 'este mês':
        return 'este mês';
      case 'mês passado':
        return 'no mês passado';
      case 'semana passada':
        return 'na semana passada';
      case 'esta semana':
        return 'esta semana';
      default:
        return label;
    }
  }

  List<FinancialTransaction> _inRange(DateRangeResult r, bool Function(FinancialTransaction) where) =>
      repository.transactions.where((t) => where(t) && r.contains(t.date)).toList();

  bool _matchesTerm(FinancialTransaction t, String term) {
    if (term.isEmpty) return true;
    final pay = _paymentCode(term);
    if (pay != null) return t.paymentMethod == pay;
    final folded = CesarText.fold(term);
    if (CesarText.fold(t.title).contains(folded)) return true;
    final code = CesarText.resolveCategory(term, repository.budgets);
    return code != null && t.category == code;
  }

  QaAnswer _spending(QaQuery q, String? originalText) {
    final r = _range(q.period);
    final items = repository.getSpendingByCategoryOrTerm(q.term, start: r.start, end: r.end)
      ..sort((a, b) => b.date.compareTo(a.date));
    final total = items.fold(0.0, (a, t) => a + t.amount);
    final when = _periodPhrase(r.label);
    final what = _termPhrase(q.term, originalText);

    if (items.isEmpty) {
      final text = 'Você não teve gastos$what $when.';
      return QaAnswer(text: '💳 $text', spokenText: text, query: q);
    }

    var spoken = 'Você gastou ${CesarText.money(total)}$what $when, em ${items.length} ${items.length == 1 ? 'lançamento' : 'lançamentos'}.';
    final code = _paymentCode(q.term) == null && q.term.isNotEmpty ? CesarText.resolveCategory(q.term, repository.budgets) : null;
    final budget = code == null ? null : repository.budgets.where((b) => b.category == code).firstOrNull;
    if (budget != null && budget.monthlyLimit > 0 && (q.period == null || q.period == 'este mês')) {
      final pct = (total / budget.monthlyLimit * 100).round();
      spoken += ' Isso é $pct% do orçamento de ${budget.name} (${CesarText.money(budget.monthlyLimit)}).';
    }
    final list = items
        .take(8)
        .map((t) => '- ${CesarText.ddmm(t.date)} · ${t.title} — ${CesarText.money(t.amount)}'
            '${t.paymentMethod == 'unknown' ? '' : ' (${CesarText.paymentName(t.paymentMethod)})'}')
        .join('\n');
    final more = items.length > 8 ? '\n… e mais ${items.length - 8}.' : '';
    ReportChartData? chart;
    if (originalText != null && FinancialReportRagEngine.wantsChart(originalText)) {
      final byCat = <String, double>{};
      for (final t in items) {
        byCat[t.category] = (byCat[t.category] ?? 0) + t.amount;
      }
      chart = ReportChartData.category(byCat);
    }
    return QaAnswer(text: '💳 $spoken\n\n$list$more', spokenText: spoken, query: q, chart: chart);
  }

  static String? _paymentCode(String term) {
    final t = CesarText.fold(term);
    if (RegExp(r'^(?:pix|pics)$').hasMatch(t)) return 'pix';
    if (RegExp(r'^(?:cartao\s+de\s+)?debito$').hasMatch(t)) return 'debit_card';
    if (RegExp(r'^(?:cartao\s+de\s+)?credito$|^cartao$').hasMatch(t)) return 'credit_card';
    if (RegExp(r'^(?:dinheiro|especie)$').hasMatch(t)) return 'cash';
    if (RegExp(r'^boletos?$').hasMatch(t)) return 'bank_slip';
    return null;
  }

  /// " no Pix", " com saúde", "" — the filter as it reads in the answer, with
  /// the user's own accents when the term came from their text.
  static String _termPhrase(String term, String? originalText) {
    if (term.isEmpty) return '';
    final pay = _paymentCode(term);
    if (pay != null) return pay == 'pix' ? ' no Pix' : ' no ${CesarText.paymentName(pay)}';
    return ' com ${_originalSpelling(term, originalText)}';
  }

  /// [folded] as a brand is spelled in some title ("ifood" → "iFood").
  String _titleSpelling(String folded) => CesarText.brandSpelling(folded, repository.transactions.map((t) => t.title));

  /// The substring of [original] that folds to [folded] ("saúde" for "saude").
  static String _originalSpelling(String folded, String? original) {
    if (original == null) return folded;
    final lower = original.toLowerCase();
    for (var i = 0; i + folded.length <= lower.length; i++) {
      if (CesarText.fold(lower.substring(i, i + folded.length)) == folded) {
        return lower.substring(i, i + folded.length);
      }
    }
    return folded;
  }

  QaAnswer _income(QaQuery q) {
    final r = _range(q.period);
    final items = _inRange(r, (t) => t.type == TransactionType.income && _matchesTerm(t, q.term))
      ..sort((a, b) => b.date.compareTo(a.date));
    final total = items.fold(0.0, (a, t) => a + t.amount);
    final what = q.term.isEmpty ? '' : ' de ${q.term}';
    final when = _periodPhrase(r.label);
    if (items.isEmpty) {
      final text = 'Não encontrei nenhuma receita$what $when.';
      return QaAnswer(text: text, spokenText: text, query: q);
    }
    final list = items.take(5).map((t) => '- ${CesarText.ddmm(t.date)} · ${t.title} — ${CesarText.money(t.amount)}').join('\n');
    final spoken = 'Você recebeu ${CesarText.money(total)}$what $when, em ${items.length} ${items.length == 1 ? 'entrada' : 'entradas'}.';
    return QaAnswer(text: '💰 $spoken\n\n$list', spokenText: spoken, query: q);
  }

  QaAnswer _extreme(QaQuery q) {
    final r = _range(q.period);
    final smallest = q.kind == QaKind.smallestExpense;
    final items = _inRange(r, (t) => t.type == TransactionType.expense && _matchesTerm(t, q.term))
      ..sort((a, b) => smallest ? a.amount.compareTo(b.amount) : b.amount.compareTo(a.amount));
    final when = _periodPhrase(r.label);
    if (items.isEmpty) {
      final text = 'Não encontrei gastos $when para comparar.';
      return QaAnswer(text: text, spokenText: text, query: q);
    }
    final word = smallest ? 'menor' : 'maior';
    final now = _clock();
    if (q.rank > 1) {
      const ordinal = {2: 'segundo', 3: 'terceiro', 4: 'quarto', 5: 'quinto'};
      if (items.length < q.rank) {
        final text = 'Você só tem ${items.length} ${items.length == 1 ? 'gasto' : 'gastos'} $when, então não há um ${ordinal[q.rank]} $word.';
        return QaAnswer(text: text, spokenText: text, query: q);
      }
      final t = items[q.rank - 1];
      final text = 'Seu ${ordinal[q.rank]} $word gasto $when foi **${t.title}**: ${CesarText.money(t.amount)} em ${CesarText.ddmm(t.date)}'
          '${t.paymentMethod == 'unknown' ? '' : ' (${CesarText.paymentName(t.paymentMethod)})'}.';
      return QaAnswer(text: text, spokenText: text.replaceAll('**', ''), query: q);
    }
    if (q.limit <= 1) {
      final t = items.first;
      final cat = CesarText.categoryName(t.category, repository.budgets);
      final text = 'Seu $word gasto $when foi **${t.title}**: ${CesarText.money(t.amount)} em ${CesarText.ddmm(t.date)}'
          '${t.paymentMethod == 'unknown' ? '' : ' (${CesarText.paymentName(t.paymentMethod)})'}, na categoria $cat.';
      final spoken = 'Seu $word gasto $when foi ${t.title}, de ${CesarText.money(t.amount)}.';
      return QaAnswer(text: text, spokenText: spoken, query: q);
    }
    final top = items.take(q.limit).toList();
    final list = [for (var i = 0; i < top.length; i++) '${i + 1}. ${CesarText.describe(top[i], now)}'].join('\n');
    final spoken = 'Seus ${word == 'maior' ? 'maiores' : 'menores'} gastos $when foram ${top.map((t) => '${t.title}, ${CesarText.money(t.amount)}').join('; ')}.';
    return QaAnswer(text: 'Seus ${top.length} ${word == 'maior' ? 'maiores' : 'menores'} gastos $when:\n$list', spokenText: spoken, query: q);
  }

  QaAnswer _topCategory(QaQuery q) {
    final r = _range(q.period);
    final byCat = <String, double>{};
    for (final t in _inRange(r, (t) => t.type == TransactionType.expense)) {
      byCat[t.category] = (byCat[t.category] ?? 0) + t.amount;
    }
    final when = _periodPhrase(r.label);
    if (byCat.isEmpty) {
      final text = 'Você não tem gastos registrados $when.';
      return QaAnswer(text: text, spokenText: text, query: q);
    }
    final ranked = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = byCat.values.fold(0.0, (a, v) => a + v);
    final first = ranked.first;
    final firstName = CesarText.categoryName(first.key, repository.budgets);
    final pct = (first.value / total * 100).round();
    final next = ranked.skip(1).take(2).map((e) => '${CesarText.categoryName(e.key, repository.budgets)} (${CesarText.money(e.value)})').join(' e ');
    final spoken = 'Você mais gastou com $firstName $when: ${CesarText.money(first.value)}, $pct% das suas despesas.';
    final text = '📊 $spoken${next.isEmpty ? '' : '\nEm seguida vêm $next.'}';
    return QaAnswer(text: text, spokenText: spoken, query: q, chart: ReportChartData.category(byCat));
  }

  ({double income, double expense}) _month(DateTime ref) {
    var income = 0.0, expense = 0.0;
    for (final t in repository.transactions) {
      if (t.date.year != ref.year || t.date.month != ref.month) continue;
      if (t.type == TransactionType.income) {
        income += t.amount;
      } else {
        expense += t.amount;
      }
    }
    return (income: income, expense: expense);
  }

  QaAnswer _balance(QaQuery q) {
    final balance = repository.totalBalance;
    final m = _month(_clock());
    final spoken = 'Seu saldo atual é de ${CesarText.money(balance)}. Este mês entraram ${CesarText.money(m.income)} e saíram ${CesarText.money(m.expense)}.';
    return QaAnswer(text: '🏦 $spoken', spokenText: spoken, query: q);
  }

  QaAnswer _inTheRed(QaQuery q) {
    final balance = repository.totalBalance;
    final m = _month(_clock());
    final String spoken;
    if (balance < 0) {
      spoken = 'Sim, seu saldo está negativo em ${CesarText.money(balance.abs())}. Vale segurar os gastos até a próxima entrada.';
    } else if (m.expense > m.income) {
      spoken = 'Seu saldo geral ainda está positivo (${CesarText.money(balance)}), mas este mês você já gastou '
          '${CesarText.money(m.expense - m.income)} a mais do que recebeu.';
    } else {
      spoken = 'Não! Seu saldo está positivo: ${CesarText.money(balance)}. Este mês sobram '
          '${CesarText.money(m.income - m.expense)} entre o que entrou e o que saiu.';
    }
    return QaAnswer(text: spoken, spokenText: spoken, query: q);
  }

  QaAnswer _recent(QaQuery q) {
    final incomeOnly = q.term == 'receitas';
    final r = q.period == null ? null : _range(q.period);
    final items = repository.transactions
        .where((t) => (r == null || r.contains(t.date)) && (!incomeOnly || t.type == TransactionType.income))
        .toList()
      ..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : b.id.compareTo(a.id);
      });
    final when = r == null ? '' : ' ${_periodPhrase(r.label)}';
    if (items.isEmpty) {
      final text = 'Não encontrei lançamentos$when.';
      return QaAnswer(text: text, spokenText: text, query: q);
    }
    final top = items.take(q.limit).toList();
    final list = top
        .map((t) => '- ${CesarText.ddmm(t.date)} · ${t.title} — ${CesarText.money(t.amount)} '
            '(${CesarText.typeName(t.type)}${t.paymentMethod == 'unknown' ? '' : ', ${CesarText.paymentName(t.paymentMethod)}'})')
        .join('\n');
    final title = r == null ? 'Seus últimos ${top.length} lançamentos' : 'Seus lançamentos$when';
    final spoken = '$title: ${top.take(3).map((t) => '${t.title}, ${CesarText.money(t.amount)}').join('; ')}'
        '${top.length > 3 ? ' e mais ${top.length - 3}' : ''}.';
    return QaAnswer(text: '🧾 $title:\n$list\n\nPara mudar ou apagar algum, é só me dizer (ex.: "apaga o ${top.first.title.split(' ').first.toLowerCase()}").', spokenText: spoken, query: q);
  }

  QaAnswer _dailyBudget(QaQuery q) {
    final now = _clock();
    final m = _month(now);
    final lastDay = DateTime(now.year, now.month + 1, 0).day;
    final daysLeft = lastDay - now.day + 1;
    final bills = repository.getUpcomingBills(
      start: CesarText.dayOnly(now),
      end: DateTime(now.year, now.month, lastDay, 23, 59, 59),
    );
    final billsTotal = bills.fold(0.0, (a, b) => a + ((b['amount'] as num?)?.toDouble() ?? 0));
    final free = m.income - m.expense - billsTotal;
    final billsNote = billsTotal > 0 ? ' e ainda vencem ${CesarText.money(billsTotal)} em contas' : '';
    final String spoken;
    if (free <= 0) {
      spoken = 'Este mês não sobra margem: entraram ${CesarText.money(m.income)}, saíram ${CesarText.money(m.expense)}$billsNote. '
          'O ideal é evitar novos gastos até a próxima entrada.';
    } else {
      final perDay = free / daysLeft;
      spoken = 'Dá para gastar cerca de ${CesarText.money(perDay)} por dia até o fim do mês ($daysLeft ${daysLeft == 1 ? 'dia' : 'dias'}). '
          'Conta: entraram ${CesarText.money(m.income)}, saíram ${CesarText.money(m.expense)}$billsNote, sobrando ${CesarText.money(free)}.';
    }
    return QaAnswer(text: '🧮 $spoken', spokenText: spoken, query: q);
  }

  /// Next expected income: the next occurrence of a recurring income's due
  /// day, else the day of the month the last salary came in. Null = unknown.
  DateTime? _nextIncomeDate(DateTime today) {
    int? day;
    for (final t in repository.transactions) {
      if (t.type != TransactionType.income) continue;
      if (t.isRecurrent && t.dueDay != null) {
        day = t.dueDay;
        break;
      }
    }
    if (day == null) {
      final salaries = repository.transactions.where((t) => t.type == TransactionType.income && t.category == 'salary').toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      if (salaries.isNotEmpty) day = salaries.first.date.day;
    }
    if (day == null) return null;
    var next = DateTime(today.year, today.month, day);
    if (!next.isAfter(today)) next = DateTime(today.year, today.month + 1, day);
    return next;
  }

  QaAnswer _freeUntilIncome(QaQuery q) {
    final today = CesarText.dayOnly(_clock());
    final next = _nextIncomeDate(today);
    final until = next ?? DateTime(today.year, today.month + 1, 0);
    final bills = repository.getUpcomingBills(start: today, end: DateTime(until.year, until.month, until.day, 23, 59, 59));
    final billsTotal = bills.fold(0.0, (a, b) => a + ((b['amount'] as num?)?.toDouble() ?? 0));
    final balance = repository.totalBalance;
    final free = balance - billsTotal;
    final days = until.difference(today).inDays.clamp(1, 62);
    final when = next == null ? 'até o fim do mês (não sei quando cai sua próxima receita)' : 'até ${CesarText.ddmm(next)}, quando deve cair sua próxima receita';
    final billsNote = billsTotal > 0 ? ', já descontando ${CesarText.money(billsTotal)} em contas que vencem antes' : '';
    final String spoken;
    if (free <= 0) {
      spoken = 'Não sobra dinheiro livre $when: seu saldo é ${CesarText.money(balance)}$billsNote.';
    } else {
      spoken = 'Você tem ${CesarText.money(free)} livres $when$billsNote. Dá uns ${CesarText.money(free / days)} por dia ($days ${days == 1 ? 'dia' : 'dias'}).';
    }
    return QaAnswer(text: '🧮 $spoken', spokenText: spoken, query: q);
  }

  /// The filters of a search as they read in the answer: " com ifood acima
  /// de R$ 100,00 no Pix".
  String _filtersPhrase(QaQuery q, [String? originalText]) {
    final parts = <String>[];
    if (q.term.isNotEmpty) {
      // A brand as its titles spell it ("iFood"), else the user's own accents ("remédio").
      final brand = _titleSpelling(q.term);
      parts.add(' com ${brand != q.term ? brand : _originalSpelling(q.term, originalText)}');
    }
    if (q.minAmount != null && q.maxAmount != null) {
      parts.add(' entre ${CesarText.money(q.minAmount!)} e ${CesarText.money(q.maxAmount!)}');
    } else if (q.minAmount != null) {
      parts.add(' acima de ${CesarText.money(q.minAmount!)}');
    } else if (q.maxAmount != null) {
      parts.add(' até ${CesarText.money(q.maxAmount!)}');
    }
    if (q.payment != null) parts.add(q.payment == 'pix' ? ' no Pix' : ' no ${CesarText.paymentName(q.payment!)}');
    return parts.join();
  }

  /// "mostra os gastos acima de 100 no crédito esse mês": every record that
  /// passes all the filters, newest first, with the total.
  QaAnswer _search(QaQuery q, String? originalText) {
    final always = q.period == 'sempre';
    final r = always ? null : _range(q.period);
    final folded = CesarText.fold(q.term);
    // A name found in some title ("ifood") or note ("churrasco") filters by
    // titles and notes only — not its whole category (the Cinemark is
    // leisure too).
    bool Function(FinancialTransaction)? named;
    if (q.term.isNotEmpty) {
      bool said(FinancialTransaction t) => CesarText.fold(t.title).contains(folded) || CesarText.fold(t.notes ?? '').contains(folded);
      named = repository.transactions.any(said) ? said : (t) => _matchesTerm(t, q.term);
    }
    final items = repository.transactions.where((t) {
      if (q.incomeOnly ? t.type != TransactionType.income : t.type != TransactionType.expense) return false;
      if (r != null && !r.contains(t.date)) return false;
      if (q.minAmount != null && t.amount < q.minAmount! - 0.001) return false;
      if (q.maxAmount != null && t.amount > q.maxAmount! + 0.001) return false;
      if (q.payment != null && t.paymentMethod != q.payment) return false;
      if (named != null && !named(t)) return false;
      return true;
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final what = q.incomeOnly ? 'receitas' : 'gastos';
    final when = always ? ' desde o início' : ' ${_periodPhrase(r!.label)}';
    final filters = _filtersPhrase(q, originalText);
    if (items.isEmpty) {
      final text = 'Não achei $what$filters$when.';
      return QaAnswer(text: '🔎 $text', spokenText: text, query: q);
    }
    final total = items.fold(0.0, (a, t) => a + t.amount);
    final head = '${items.length} ${items.length == 1 ? (q.incomeOnly ? 'receita' : 'gasto') : what}$filters$when, somando ${CesarText.money(total)}';
    final list = items
        .take(q.limit)
        .map((t) => '- ${CesarText.ddmm(t.date)} · ${t.title} — ${CesarText.money(t.amount)}'
            '${t.paymentMethod == 'unknown' ? '' : ' (${CesarText.paymentName(t.paymentMethod)})'}'
            '${(t.notes ?? '').isEmpty ? '' : ' — 📝 ${t.notes}'}')
        .join('\n');
    final more = items.length > q.limit ? '\n… e mais ${items.length - q.limit}.' : '';
    return QaAnswer(text: '🔎 $head:\n$list$more', spokenText: 'Achei $head.', query: q);
  }

  /// "quanto eu economizei esse mês?": income minus spending in the period.
  QaAnswer _savings(QaQuery q) {
    final r = _range(q.period);
    final income = _inRange(r, (t) => t.type == TransactionType.income).fold(0.0, (a, t) => a + t.amount);
    final spent = _inRange(r, (t) => t.type != TransactionType.income && !t.isInternalTransfer).fold(0.0, (a, t) => a + t.amount);
    final when = _periodPhrase(r.label);
    final left = income - spent;
    final String spoken;
    if (income <= 0 && spent <= 0) {
      spoken = 'Não tenho entradas nem saídas registradas $when.';
    } else if (left >= 0) {
      final pct = income > 0 ? ' (${(left / income * 100).round()}% do que entrou)' : '';
      spoken = '${_capitalized(when)} entraram ${CesarText.money(income)} e saíram ${CesarText.money(spent)}: você economizou ${CesarText.money(left)}$pct.';
    } else {
      spoken = '${_capitalized(when)} entraram ${CesarText.money(income)} e saíram ${CesarText.money(spent)}: você gastou ${CesarText.money(-left)} a mais do que entrou.';
    }
    final saved = repository.goals.fold(0.0, (a, g) => a + g.savedAmount);
    final goals = saved > 0 ? '\n\n🎯 Nas suas metas, você tem ${CesarText.money(saved)} guardados.' : '';
    return QaAnswer(text: '💰 $spoken$goals', spokenText: spoken, query: q);
  }

  static String _capitalized(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  QaAnswer _goals(QaQuery q) {
    final active = repository.goals.where((g) => !g.isCompleted).toList();
    final all = repository.goals;
    if (all.isEmpty) {
      const text = 'Você ainda não tem metas. Quer criar uma? Ex.: "quero juntar 5000 para uma viagem até dezembro".';
      return QaAnswer(text: text, spokenText: text, query: q);
    }
    var list = q.term.isEmpty ? active : repository.findGoalsByTitle(q.term);
    if (q.term.isNotEmpty && list.isEmpty) {
      final names = all.map((g) => '"${g.title}"').join(', ');
      final text = 'Não achei uma meta chamada "${q.term}". Suas metas: $names.';
      return QaAnswer(text: text, spokenText: text, query: q);
    }
    if (list.isEmpty) list = all;
    String line(FinancialGoal g) {
      final pct = (g.progress * 100).round();
      final left = g.remaining > 0 ? ' — faltam ${CesarText.money(g.remaining)}' : ' — concluída! 🎉';
      return '"${g.title}": ${CesarText.money(g.savedAmount)} de ${CesarText.money(g.targetAmount)} ($pct%)$left';
    }
    if (list.length == 1) {
      final g = list.first;
      final monthly = g.suggestedMonthlyContribution;
      final tip = monthly != null && g.remaining > 0 ? ' Guardando ${CesarText.money(monthly)} por mês você chega lá no prazo.' : '';
      final text = '🎯 Meta ${line(g)}.$tip';
      return QaAnswer(text: text, spokenText: text.replaceAll('🎯 ', ''), query: q);
    }
    final text = '🎯 Suas metas:\n${list.map((g) => '- ${line(g)}').join('\n')}';
    final spoken = 'Você tem ${list.length} metas. ${list.map((g) => '${g.title}: faltam ${CesarText.money(g.remaining)}').join('; ')}.';
    return QaAnswer(text: text, spokenText: spoken, query: q);
  }

  QaAnswer _budgetRemaining(QaQuery q) {
    if (q.term.isEmpty) return _budgetsOverview(q);
    final code = CesarText.resolveCategory(q.term, repository.budgets);
    final budget = code == null ? null : repository.budgets.where((b) => b.category == code).firstOrNull;
    if (budget == null) {
      final text = 'Você não tem orçamento definido para ${q.term}. Se quiser, diga por exemplo: "meu limite de ${q.term} é 500 por mês".';
      return QaAnswer(text: text, spokenText: text, query: q);
    }
    final String spoken;
    if (budget.isOverBudget) {
      spoken = 'Você já passou ${CesarText.money(budget.currentSpent - budget.monthlyLimit)} do limite de ${budget.name} '
          '(${CesarText.money(budget.monthlyLimit)}) este mês.';
    } else {
      spoken = 'Do orçamento de ${budget.name} (${CesarText.money(budget.monthlyLimit)}), você já usou ${CesarText.money(budget.currentSpent)}. '
          'Ainda pode gastar ${CesarText.money(budget.remaining)} este mês.';
    }
    return QaAnswer(text: spoken, spokenText: spoken, query: q);
  }

  /// "estou dentro do orçamento?": every category with a limit, the ones
  /// over it and the ones close to it.
  QaAnswer _budgetsOverview(QaQuery q) {
    final withLimit = repository.budgets.where((b) => b.monthlyLimit > 0).toList();
    if (withLimit.isEmpty) {
      const text = 'Você ainda não tem limites definidos. Diga, por exemplo, "meu limite de mercado é 800" que eu passo a acompanhar.';
      return QaAnswer(text: text, spokenText: text, query: q);
    }
    final over = withLimit.where((b) => b.isOverBudget).toList();
    final near = withLimit.where((b) => b.isNearLimit).toList();
    final spent = withLimit.fold(0.0, (a, b) => a + b.currentSpent);
    final limits = withLimit.fold(0.0, (a, b) => a + b.monthlyLimit);
    final total = 'No total, você usou ${CesarText.money(spent)} de ${CesarText.money(limits)} (${(spent / limits * 100).round()}%).';
    String pct(BudgetCategory b) => '${b.name} (${(b.currentSpent / b.monthlyLimit * 100).round()}%)';
    final String head, icon;
    if (over.isEmpty && near.isEmpty) {
      icon = '✅';
      head = 'Sim! Você está dentro de todos os ${withLimit.length} orçamentos este mês.';
    } else if (over.isEmpty) {
      icon = '🟡';
      head = 'Está dentro, mas perto do limite em ${near.map(pct).join(' e ')}.';
    } else {
      icon = '🔴';
      head = 'Você passou do limite em ${over.map((b) => '${b.name} (${CesarText.money(b.currentSpent - b.monthlyLimit)} acima)').join(' e ')}'
          '${near.isEmpty ? '' : '; perto do limite: ${near.map(pct).join(' e ')}'}.';
    }
    final list = withLimit
        .map((b) => '- ${b.name}: ${CesarText.money(b.currentSpent)} de ${CesarText.money(b.monthlyLimit)} (${(b.currentSpent / b.monthlyLimit * 100).round()}%)')
        .join('\n');
    return QaAnswer(text: '$icon $head $total\n\n$list', spokenText: '$head $total', query: q);
  }

  QaAnswer _comparison(QaQuery q) {
    final now = _clock();
    // This month (or week) against the period named — "que em agosto",
    // "que a semana passada" — or, by default, the month before.
    final versus = q.period ?? 'mês passado';
    final weekly = versus == 'semana passada';
    final filter = q.term.isEmpty ? (FinancialTransaction t) => true : _titleOrCategory(q.term);
    double spentIn(DateRangeResult r) => _inRange(r, (t) => t.type != TransactionType.income && filter(t)).fold(0.0, (a, t) => a + t.amount);
    double monthOf(DateTime ref) => q.term.isEmpty
        ? _month(ref).expense
        : repository.transactions
            .where((t) => t.type != TransactionType.income && t.date.year == ref.year && t.date.month == ref.month && filter(t))
            .fold(0.0, (a, t) => a + t.amount);
    final cur = weekly ? spentIn(_range('esta semana')) : monthOf(now);
    final prev = versus == 'mês passado' ? monthOf(DateTime(now.year, now.month - 1)) : spentIn(_range(versus));
    final curLabel = weekly ? 'Esta semana' : 'Este mês';
    final prevLabel = versus == 'mês passado' ? 'no mês passado' : (weekly ? 'na semana passada' : versus);
    final what = q.term.isEmpty ? '' : (_paymentCode(q.term) != null ? _termPhrase(q.term, null) : ' com ${_titleSpelling(q.term)}');
    final String spoken;
    if (prev <= 0) {
      spoken = '$curLabel você gastou ${CesarText.money(cur)}$what. Não tenho gastos${what.isEmpty ? '' : what} registrados $prevLabel para comparar.';
    } else {
      final diff = cur - prev;
      final pct = (diff.abs() / prev * 100).round();
      final trend = diff.abs() < 0.01 ? 'o mesmo que' : (diff > 0 ? '$pct% a mais que' : '$pct% a menos que');
      final ref = versus == 'mês passado' ? 'o mês passado' : prevLabel;
      spoken = '$curLabel você gastou ${CesarText.money(cur)}$what; $prevLabel, ${CesarText.money(prev)}. Isso é $trend $ref.';
    }
    return QaAnswer(text: '📈 $spoken', spokenText: spoken, query: q);
  }

  /// A merchant named in some title ("ifood") filters by the title only —
  /// not by its category, which would count every delivery. Otherwise the
  /// term is a category ("mercado", "saúde").
  bool Function(FinancialTransaction) _titleOrCategory(String term) {
    final folded = CesarText.fold(term);
    final inTitles = folded.isNotEmpty && repository.transactions.any((t) => CesarText.fold(t.title).contains(folded));
    return inTitles ? (t) => CesarText.fold(t.title).contains(folded) : (t) => _matchesTerm(t, term);
  }

  QaAnswer _count(QaQuery q) {
    final r = _range(q.period);
    final items = _inRange(r, _titleOrCategory(q.term));
    final total = items.fold(0.0, (a, t) => a + t.amount);
    final when = _periodPhrase(r.label);
    final text = items.isEmpty
        ? 'Não encontrei nenhum lançamento com "${q.term}" $when.'
        : '${items.length} ${items.length == 1 ? 'vez' : 'vezes'} com "${q.term}" $when '
            '(${items.length} ${items.length == 1 ? 'lançamento' : 'lançamentos'}), somando ${CesarText.money(total)}.';
    return QaAnswer(text: text, spokenText: text, query: q);
  }

  QaAnswer _lastTime(QaQuery q) {
    final items = repository.transactions.where(_titleOrCategory(q.term)).toList()..sort((a, b) => b.date.compareTo(a.date));
    if (items.isEmpty) {
      final text = 'Não encontrei nenhum lançamento com "${q.term}".';
      return QaAnswer(text: text, spokenText: text, query: q);
    }
    final t = items.first;
    final text = 'A última vez foi em ${CesarText.ddmm(t.date)}: ${t.title}, ${CesarText.money(t.amount)}.';
    return QaAnswer(text: text, spokenText: text, query: q);
  }

  QaAnswer _viaRag(QaQuery q, String? originalText) {
    final String canonical;
    switch (q.kind) {
      case QaKind.bills:
        canonical = 'quais contas vencem ${q.period ?? 'esta semana'}';
        break;
      case QaKind.debtors:
        canonical = originalText ?? 'quem me deve';
        break;
      default:
        canonical = originalText ?? 'como estão minhas finanças';
    }
    final rag = FinancialReportRagEngine(repository: repository).generateReport(canonical);
    return QaAnswer(text: rag.formattedText, spokenText: rag.spokenText, query: q, chart: rag.chart);
  }
}
