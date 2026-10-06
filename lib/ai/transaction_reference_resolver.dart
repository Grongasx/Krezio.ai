import '../backend/models/budget_category.dart';
import '../backend/models/financial_transaction.dart';
import 'category_name_matcher.dart';
import 'cesar_text.dart';
import 'local_nlp_engine.dart';
import 'temporal_date_parser.dart';

/// What a reference phrase ("o uber de ontem", "o anterior", "os dois
/// últimos", "o de 48", "os lançamentos de hoje") asks for, before looking at
/// the data.
class ReferenceSpec {
  /// 1 = "o último"/"esse", 2 = "o anterior"/"penúltimo"; null = not positional.
  final int? position;

  /// "os dois últimos" → 2.
  final int? lastCount;

  /// Merchant/description/category words ("uber", "aluguel", "netflix").
  final List<String> terms;
  final DateTime? dayStart;
  final DateTime? dayEnd;
  final String? dateLabel;
  final double? amount;

  /// Only expenses ("o gasto de ontem") or only income ("a receita de hoje").
  final TransactionType? type;

  /// "os lançamentos de hoje", "todos os ubers" — every match, not one.
  final bool plural;

  /// "o primeiro", "o segundo": counted from the start of what the chat
  /// recorded recently (the caller decides what "recently" is).
  final int? fromStart;

  /// Why the date said can't exist ("setembro não tem dia 31", "o mês 13 não
  /// existe"), or null. The caller asks instead of searching a wrong day.
  final String? invalidDate;

  /// The words that said the date ("sabado", "dia 7") — a record may carry
  /// them in its title ("Pizzaria Sábado", "Bar Dia 7").
  final String? dateWords;

  const ReferenceSpec({
    this.position,
    this.lastCount,
    this.terms = const [],
    this.dayStart,
    this.dayEnd,
    this.dateLabel,
    this.amount,
    this.type,
    this.plural = false,
    this.invalidDate,
    this.fromStart,
    this.dateWords,
  });

  bool get isEmpty =>
      position == null && lastCount == null && terms.isEmpty && dayStart == null && amount == null && type == null && fromStart == null;

  /// Only "esse"/"o último"/"isso" — i.e. the most recent thing César did.
  bool get isJustLast =>
      (position == 1 || isEmpty) && terms.isEmpty && dayStart == null && amount == null && lastCount == null && type == null && fromStart == null;

  ReferenceSpec copyWith({double? amount, bool clearAmount = false, List<String>? terms}) => ReferenceSpec(
        position: position,
        lastCount: lastCount,
        terms: terms ?? this.terms,
        dayStart: dayStart,
        dayEnd: dayEnd,
        dateLabel: dateLabel,
        amount: clearAmount ? null : (amount ?? this.amount),
        type: type,
        plural: plural,
        invalidDate: invalidDate,
        fromStart: fromStart,
        dateWords: dateWords,
      );

  /// "de 'uber' ontem" — how the search is described back to the user.
  String describe() {
    final parts = <String>[];
    if (terms.isNotEmpty) parts.add("de '${terms.join(' ')}'");
    if (terms.isEmpty && type != null) {
      parts.add(type == TransactionType.income ? 'de receita' : (type == TransactionType.transfer ? 'de transferência' : 'de gasto'));
    }
    if (amount != null) parts.add('de ${CesarText.money(amount!)}');
    if (dateLabel != null) parts.add(dateLabel!);
    return parts.isEmpty ? 'recente' : parts.join(' ');
  }
}

class ReferenceResolution {
  final ReferenceSpec spec;

  /// Best matches, most recent first. One → act on it; several → ask which
  /// (unless [ReferenceSpec.plural]); none → say what was searched.
  final List<FinancialTransaction> matches;

  /// When nothing matched every filter, the closest records by term alone —
  /// offered as suggestions ("os últimos com 'uber' foram 14/09 e 10/09").
  final List<FinancialTransaction> suggestions;

  /// The [matches] share only a category with the words said — no word said
  /// is in their titles ("o uber de domingo" → "Estacionamento Centro",
  /// "a feira de ontem" → "Mercado Dia a Dia"). The caller must show the
  /// record and ask, never act on it directly (CHAOS-B-014/026).
  final bool byCategoryOnly;

  const ReferenceResolution(this.spec, this.matches, {this.suggestions = const [], this.byCategoryOnly = false});
}

/// Finds the transaction(s) a chat phrase refers to — by description,
/// category, relative date, value or position — so César can edit or delete
/// any record, not only the last one. Pure: the caller hands in the records
/// and the ids of what the chat itself created (most recent last), which is
/// what "o último"/"esse"/"o anterior" point to.
class TransactionReferenceResolver {
  TransactionReferenceResolver._();

  static const _weekdays = {
    'segunda': DateTime.monday, 'terca': DateTime.tuesday, 'quarta': DateTime.wednesday, 'quinta': DateTime.thursday,
    'sexta': DateTime.friday, 'sabado': DateTime.saturday, 'domingo': DateTime.sunday,
  };

  static const _countWords = {'dois': 2, 'duas': 2, 'tres': 3, 'quatro': 4, 'cinco': 5, '2': 2, '3': 3, '4': 4, '5': 5};

  /// Words that carry no search meaning in a reference.
  static const _stop = {
    'o', 'a', 'os', 'as', 'do', 'da', 'dos', 'das', 'de', 'no', 'na', 'nos', 'nas', 'em', 'com', 'pra', 'para', 'pro',
    'meu', 'minha', 'meus', 'minhas', 'um', 'uma', 'que', 'eu', 'fiz', 'lancei', 'registrei', 'gastei', 'paguei', 'comprei',
    'foi', 'e', 'la', 'aquele', 'aquela', 'ai', 'valor', 'lancamento', 'lancamentos', 'registro', 'registros', 'transacao',
    'transacoes', 'item', 'itens', 'dia', 'todos', 'todas', 'tudo', 'por', 'favor', 'pf', 'pfv', 'ele', 'ela',
    'isso', 'isto', 'esse', 'essa', 'este', 'esta', 'ultimo', 'ultima', 'ultimos', 'ultimas', 'anterior', 'penultimo',
    'penultima', 'mais', 'recente', 'agora', 'pouco', 'so', 'tambem', 'cesar', 'categoria', 'forma', 'pagamento', 'data',
    'nome', 'descricao', 'mesmo', 'semana', 'passada', 'hoje', 'ontem', 'anteontem', 'mes', 'passado', 'atual',
    // "daquele de 89", "naquela da padaria": de/em + aquele is still "aquele".
    'daquele', 'daquela', 'naquele', 'naquela', 'deste', 'desse', 'dessa', 'desta', 'neste', 'nesse', 'nessa', 'nesta',
    'aqueles', 'aquelas', 'ambos', 'ambas', 'primeiro', 'primeira', 'segundo', 'terceiro', 'terceira',
    'mil', 'reais', 'real', 'conto', 'contos', 'pila', 'errado', 'errada', 'certo', 'ta', 'tava', 'era', 'eh',
  };

  /// Generic nouns: they restrict the type but aren't search terms.
  static const _expenseNouns = {'gasto', 'gastos', 'despesa', 'despesas', 'compra', 'compras', 'saida', 'saidas'};
  static const _incomeNouns = {'receita', 'receitas', 'entrada', 'entradas', 'recebimento', 'recebimentos', 'ganho', 'ganhos'};
  static const _transferNouns = {'transferencia', 'transferencias'};

  /// Parses [text] into a [ReferenceSpec] relative to [now].
  static ReferenceSpec parse(String text, {required DateTime now}) {
    // "segunda-feira" is a day; "a feira" alone is a record ("Feira livre").
    var s = SpokenDayParser.normalizeWeekdays(CesarText.simplify(text));
    String? invalidDate;

    int? position;
    int? lastCount;
    int? fromStart;
    // "o primeiro foi 15": the first of the entries just made.
    final ordinal = RegExp(r'^(?:o|a)\s+(primeir[oa]|segundo|terceir[oa])(?:\s+(?:lancamento|gasto))?$').firstMatch(s.trim());
    var plural = false;

    final countMatch = RegExp(r'\b(?:os|as)?\s*(dois|duas|tres|quatro|cinco|[2-5])\s+ultim[oa]s\b').firstMatch(s) ??
        RegExp(r'\bultim[oa]s\s+(dois|duas|tres|quatro|cinco|[2-5])\b').firstMatch(s) ??
        // "apaga os dois", "exclui ambos": the last two, said right after two entries.
        RegExp(r'^(?:os\s+|as\s+)?(dois|duas|ambos|ambas)$').firstMatch(s.trim());
    if (countMatch != null) {
      lastCount = _countWords[countMatch.group(1)!] ?? 2;
      s = s.replaceFirst(countMatch.group(0)!, ' ');
    } else if (ordinal != null) {
      fromStart = ordinal.group(1)!.startsWith('prim') ? 1 : (ordinal.group(1)!.startsWith('seg') ? 2 : 3);
    } else if (RegExp(r'\b(?:anterior|penultim[oa])\b').hasMatch(s)) {
      position = 2;
    } else if (RegExp(r'\b(?:ultim[oa]|esse|essa|este|esta|isso|isto|ele|ela|aquilo)\b').hasMatch(s)) {
      position = 1;
    }
    if (RegExp(r'\b(?:todos|todas|tudo)\b').hasMatch(s) ||
        RegExp(r'\b(?:os|as)\s+(?:lancamentos|gastos|despesas|compras|receitas|entradas|registros)\b').hasMatch(s)) {
      plural = true;
    }

    // Date — read the same way as when recording an entry (SpokenDayParser).
    DateTime? dayStart;
    DateTime? dayEnd;
    String? dateLabel;
    String? dateWords;
    final said = SpokenDayParser.parse(s, now: now);
    if (said != null) {
      final d = said.day;
      if (d != null) {
        dayStart = d.start;
        dayEnd = d.end;
        dateLabel = d.label;
      } else {
        invalidDate = said.invalid;
      }
      final matched = d?.matched ?? said.matched;
      if (matched != null) s = s.replaceFirst(matched, ' ');
      if (d != null) dateWords = d.matched;
    }

    // Value: "o de 48", "de R$ 48,90".
    double? amount;
    // Thousands too: "o de 1.400", "de R$ 1.400,00" (R2-CHAOS-015).
    final am = RegExp(r'(?:\bde\s+|r\$\s*)(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?![\d.,])(?!\s*(?:x|vezes|parcelas))(\s*mil\b)?')
        .firstMatch(s);
    if (am != null) {
      amount = LocalFinancialNlpEngine.cleanAndParseAmount(am.group(1));
      if (amount != null && am.group(2) != null) amount *= 1000;
      s = s.replaceFirst(am.group(0)!, ' ');
    }

    TransactionType? type;
    final words = s.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.any(_incomeNouns.contains)) type = TransactionType.income;
    if (words.any(_expenseNouns.contains)) type = TransactionType.expense;
    if (words.any(_transferNouns.contains)) type = TransactionType.transfer;

    // A bare number that isn't the value ("o 99 de hoje", "some com o do 99")
    // is part of a name — "Corrida 99" — not an amount (R2-CONV-022).
    final terms = words
        .where((w) => !_stop.contains(w) && !_expenseNouns.contains(w) && !_incomeNouns.contains(w) && !_transferNouns.contains(w))
        .where((w) => !_weekdays.containsKey(w))
        .where((w) => w.length > 1 && !RegExp(r'^\d+[.,]\d+$').hasMatch(w))
        .toList();

    return ReferenceSpec(
      position: position,
      lastCount: lastCount,
      terms: terms,
      dayStart: dayStart,
      dayEnd: dayEnd,
      dateLabel: dateLabel,
      amount: amount,
      type: type,
      plural: plural,
      invalidDate: invalidDate,
      fromStart: fromStart,
      dateWords: dateWords,
    );
  }

  /// How strongly [t] matches the search [terms]: number of terms found in its
  /// title or naming its category. 0 = no match.
  ///
  /// [named] are the terms that are the name of some record (in any date):
  /// for those the category alone doesn't count. "a feira de segunda" with
  /// the Feira on Saturday must not land on Monday's "Padaria" just because
  /// both are groceries (CHAOS-R3-004/005).
  static int _termScore(FinancialTransaction t, List<String> terms, List<BudgetCategory> budgets, {Set<String> named = const {}}) {
    if (terms.isEmpty) return 1;
    var score = 0;
    for (final term in terms) {
      final byTitle = _titleScore(t, term);
      if (byTitle > 0) {
        score += byTitle;
        continue;
      }
      if (named.contains(term)) continue;
      // Same category, another kind of thing: "a gasolina" is a fuel purchase
      // and may be the "Posto", never the "Uber" (CHAOS-A-015).
      if (LocalFinancialNlpEngine.namesOtherKind(term, t.title)) continue;
      // The category the word names — also through the engine's vocabulary
      // ("sacolão" → supermercado): older records were saved with the
      // category's label as title, and only the category finds them.
      final code = CesarText.categoryWords[term] ??
          _budgetCode(term, budgets) ??
          (LocalFinancialNlpEngine.isCategoryLabel(t.title) ? _guessedCategory(term) : null);
      if (code != null && code == t.category) score += 1;
    }
    return score;
  }

  /// 3 = a whole word of the title ("Mercado"), 2 = a piece of one
  /// ("Supermercado Carrefour"), 0 = the title doesn't say it.
  static int _titleScore(FinancialTransaction t, String term) {
    final single = CategoryNameMatcher.tokens(term).join(' ');
    if (CategoryNameMatcher.tokens(t.title).contains(single)) return 3;
    if (term.length >= 4 && CesarText.fold(t.title).contains(term)) return 2;
    return 0;
  }

  static String? _guessedCategory(String term) {
    if (RegExp(r'^\d+$').hasMatch(term)) return null;
    final g = LocalFinancialNlpEngine.guessCategoryFromText(term);
    return g == 'unknown' || g == 'expense_other' ? null : g;
  }

  static String? _budgetCode(String term, List<BudgetCategory> budgets) {
    for (final b in budgets) {
      if (CategoryNameMatcher.tokens(b.name).contains(CategoryNameMatcher.tokens(term).join(' '))) return b.category;
    }
    return null;
  }

  /// Most recent first: what the chat created (newest first), then the rest
  /// by date and id.
  static List<FinancialTransaction> _byRecency(List<FinancialTransaction> all, List<String> recentIds) {
    final rank = <String, int>{for (var i = 0; i < recentIds.length; i++) recentIds[i]: i};
    final list = List<FinancialTransaction>.from(all);
    list.sort((a, b) {
      final ra = rank[a.id], rb = rank[b.id];
      if (ra != null || rb != null) {
        if (ra == null) return 1;
        if (rb == null) return -1;
        return rb.compareTo(ra);
      }
      final byDate = b.date.compareTo(a.date);
      return byDate != 0 ? byDate : b.id.compareTo(a.id);
    });
    return list;
  }

  /// Resolves [spec] against [all]. [recentGroups] are the id groups the chat
  /// created, oldest first (a daily-rate entry is one group of several ids).
  static ReferenceResolution resolve(
    ReferenceSpec spec, {
    required List<FinancialTransaction> all,
    required List<List<String>> recentGroups,
    required List<BudgetCategory> budgets,
  }) {
    final byId = {for (final t in all) t.id: t};
    final groups = recentGroups.where((g) => g.any(byId.containsKey)).toList();

    // Pure position: "o último", "esse", "o anterior", "os dois últimos".
    if (spec.terms.isEmpty && spec.dayStart == null && spec.amount == null) {
      if (spec.fromStart != null) {
        // [recentGroups] is the stretch of conversation the caller considers
        // current; "o primeiro" is its oldest group.
        if (groups.length < 2 || groups.length < spec.fromStart!) return ReferenceResolution(spec, const []);
        final g = groups[spec.fromStart! - 1];
        return ReferenceResolution(spec, g.map((id) => byId[id]).whereType<FinancialTransaction>().toList());
      }
      if (spec.lastCount != null) {
        final picked = <FinancialTransaction>[];
        final source = groups.isNotEmpty
            ? groups.reversed.take(spec.lastCount!).expand((g) => g.map((id) => byId[id]).whereType<FinancialTransaction>())
            : _byRecency(all, const []).take(spec.lastCount!);
        picked.addAll(source);
        return ReferenceResolution(spec, picked);
      }
      final pos = spec.position ?? 1;
      // "apaga a transferência", "a receita era 300": the most recent record
      // of that type — never the last record of another type.
      final typed = spec.type == null
          ? groups
          : groups.where((g) => g.map((id) => byId[id]).whereType<FinancialTransaction>().any((t) => t.type == spec.type)).toList();
      if (typed.length >= pos) {
        final g = typed[typed.length - pos];
        return ReferenceResolution(spec, g.map((id) => byId[id]).whereType<FinancialTransaction>().toList());
      }
      if (spec.position == null && spec.type == null) return ReferenceResolution(spec, const []);
      final ordered = _byRecency(all, const []).where((t) => spec.type == null || t.type == spec.type).toList();
      return ReferenceResolution(spec, ordered.length >= pos ? [ordered[pos - 1]] : const []);
    }

    final recentIds = [for (final g in groups) ...g];
    final ordered = _byRecency(all, recentIds);
    bool dateOk(FinancialTransaction t) =>
        spec.dayStart == null || (!t.date.isBefore(spec.dayStart!) && !t.date.isAfter(spec.dayEnd!));
    bool amountOk(FinancialTransaction t) => spec.amount == null || (t.amount - spec.amount!).abs() < 0.009;
    bool typeOk(FinancialTransaction t) => spec.type == null || t.type == spec.type;

    final named = {for (final term in spec.terms) if (all.any((t) => _titleScore(t, term) > 0)) term};
    final scored = <FinancialTransaction, int>{};
    for (final t in ordered) {
      if (!dateOk(t) || !amountOk(t) || !typeOk(t)) continue;
      final sc = _termScore(t, spec.terms, budgets, named: named);
      if (sc > 0) scored[t] = sc;
    }
    // "a pizzaria sábado", "o bar do dia 7": nothing on that day, but a
    // record carries the date words in its own title ("Pizzaria Sábado",
    // "Bar Dia 7") — that is the one named (CHAOS-A-021).
    if (scored.isEmpty && spec.dateWords != null && spec.terms.isNotEmpty) {
      final dateWords = CesarText.fold(spec.dateWords!);
      for (final t in ordered) {
        if (!amountOk(t) || !typeOk(t)) continue;
        final title = CesarText.fold(t.title);
        // (Raw \b: in a plain Dart string '\b' is a backspace, and this never matched.)
        if (RegExp(r'\b' '${RegExp.escape(dateWords)}' r'\b').hasMatch(title) && spec.terms.every((w) => _titleScore(t, w) > 0)) scored[t] = 3;
      }
    }
    var matches = <FinancialTransaction>[];
    if (scored.isNotEmpty) {
      final best = scored.values.reduce((a, b) => a > b ? a : b);
      matches = ordered.where((t) => scored[t] == best).toList();
    }
    // "o último uber": the most recent of the matches.
    if (spec.position != null && matches.length > 1 && !spec.plural) {
      final pos = spec.position!;
      matches = matches.length >= pos ? [matches[pos - 1]] : const [];
    }

    var suggestions = const <FinancialTransaction>[];
    if (matches.isEmpty && spec.terms.isNotEmpty) {
      suggestions = ordered.where((t) => _termScore(t, spec.terms, budgets, named: named) > 0).take(3).toList();
    }
    // Only the category ties the words to these records: none of the words
    // said is in any of their titles. Then César shows the record and asks
    // "é esse?" before editing or deleting — also when the word is the same
    // kind of thing ("a gasolina" for the "Posto"): the user decided on
    // 2026-10-01 that a name not in the title is always confirmed.
    final byCategoryOnly = matches.isNotEmpty &&
        spec.terms.isNotEmpty &&
        matches.every((t) => spec.terms.every((w) => _titleScore(t, w) == 0)) &&
        !(spec.dateWords != null && matches.every((t) => CesarText.fold(t.title).contains(CesarText.fold(spec.dateWords!))));
    return ReferenceResolution(spec, matches, suggestions: suggestions, byCategoryOnly: byCategoryOnly);
  }
}
