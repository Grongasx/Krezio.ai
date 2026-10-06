import '../backend/models/budget_category.dart';
import 'cesar_text.dart';
import 'pt_number_words.dart';
import 'transaction_command_parser.dart';

/// A verbless correction of a record the user names: "o do posto de terça
/// foi 170", "aquele de 89 foi no dinheiro", "foi 26 o 99 de hoje", "nem era
/// 150 o posto, era 140", "a academia agora é 129,90".
class ReferenceEdit {
  /// Words that identify the record ("o do posto de terca", "aquele de 89").
  final String reference;

  /// The new field(s): value, payment, installments, date, type or category.
  final TransactionChanges changes;

  /// The value the user said it was NOT ("…e não 45", "nem era 150"): the
  /// record's current value, used to tell apart records with the same name.
  final double? oldAmount;

  /// The sentence itself says it corrects something ("aquele…", "era",
  /// "agora é", "na verdade", "tá errado", a negated old value) — as opposed
  /// to "o almoço foi 36", which may also be a new lunch.
  final bool explicitCorrection;

  /// "na verdade o X foi N": a correction marker before a record named by
  /// its own words — X must exist; it never means the last record (7e).
  final bool namesRecordAfterMarker;

  const ReferenceEdit(this.reference, this.changes,
      {this.oldAmount, this.explicitCorrection = false, this.namesRecordAfterMarker = false});

  @override
  String toString() => 'ReferenceEdit(ref="$reference", $changes, old=$oldAmount, explicit=$explicitCorrection)';
}

/// Structural rule (R2-CONV-004/005, R2-FEAT-001): a sentence with **no verb
/// of its own entry** that **names an existing record** (by name, value,
/// date or position) and brings **one new field** is an edit of that record.
/// The sentence splits at the copula ("foi", "era", "é", "tá", "veio",
/// "deu"…): the noun phrase with a determiner is the reference, the other
/// side is the change. Both orders work ("o 99 de hoje foi 26" / "foi 26 o
/// 99 de hoje"). Whether the record exists is up to the caller: this class
/// is pure and only reads the sentence.
class ReferenceEditParser {
  ReferenceEditParser._();

  static const _determiner = r'(?:aquele|aquela|aqueles|aquelas|daquele|daquela|o|a|os|as|esse|essa|este|esta)';
  static const _copula = r'(?:foi|era|eh|ta|tava|esta|estava|fica|ficou|veio|deu|custou|saiu|sai|caiu|entrou|chegou|vai\s+ser|passou\s+a\s+ser)';
  static const _softeners = r'(?:(?:na\s+verdade|na\s+real|agora|entao|mesmo|tambem|so|ja)\s+)*';

  /// A correction marker opening the sentence, when a determiner and a noun
  /// follow ("na verdade foi 45" stays with the last record).
  // ("o 7 belo", "o 123 milhas": a name may start with a number, CHAOS-C-005.)
  static final _correctionLead =
      RegExp(r'^(?:na\s+verdade|na\s+real|alias|corrigindo|me\s+enganei|errei|pensando\s+bem|melhor\s+dizendo|quer\s+dizer)\s+(?=(?:o|a|os|as|aquele|aquela)\s+[a-z0-9])');

  /// Said at the end, nothing to do with the record: "o açougue foi 92 viu",
  /// "…, tá?", "…, beleza" (ACC-C-008).
  static final _trailingFiller = RegExp(r'(?:\s+(?:viu|ta|ok|ne|beleza|blz|ta\s+bom|ta\s+certo|valeu|obrigad[oa]|tchau|pode\s+ser|por\s+favor))+$');

  /// Interjections and connectives before the sentence proper.
  static final _lead = RegExp(r'^(?:(?:ah|ahn|ai|opa|ops|olha|entao|mas|e|cesar|ei|oi|pois|tipo|ne)\s+)+');

  /// A first-person entry verb in the main clause: the sentence tells a new
  /// entry ("o mercado de ontem estava cheio, gastei 80").
  static final _entryVerb = RegExp(
    r'\b(?:gastei|gastamos|paguei|pagamos|comprei|compramos|recebi|recebemos|transferi|ganhei|torrei|larguei|desembolsei|pedi|'
    r'almocei|jantei|lanchei|abasteci|depositei|mandei|investi|quitei|tomei|comi|bebi|peguei|botei|coloquei|deixei)\b',
  );

  static ReferenceEdit? parse(String text, {required DateTime now, required List<BudgetCategory> budgets}) {
    final raw = text.trim();
    if (raw.isEmpty || raw.endsWith('?')) return null;
    // "é" with the accent is the copula; the fold below would make it "e" (and).
    final marked = raw.replaceAll(RegExp(r'(?<![\wÀ-ÿ])[éÉ](?![\wÀ-ÿ])'), ' eh ');
    // "ô césar, muda aí…": the vocative's "ô" is no article (ACC-B-016).
    var s = PtNumberWords.normalize(CesarText.simplify(marked))
        // "na vdd", "nvdd": "na verdade" typed short (ACC-C-008).
        .replaceAll(RegExp(r'\bna\s+vdd\b|\bnvdd\b|\bna\s+vrdd\b'), 'na verdade')
        .replaceAll(RegExp(r'[,;:!.]+(?=\s|$)'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceFirst(RegExp(r'^(?:o|oh|ow|e\s+ai|eai|ae|fala)\s+cesar\s+'), '')
        .replaceFirst(_lead, '')
        .trim();
    // "e a sapataria foi 78 na verdade", "o açougue foi 92 viu": a correction
    // marker or a filler at the end (ACC-C-008).
    var trailingMarker = false;
    s = s.replaceFirst(_trailingFiller, '').trim();
    final tail = RegExp(r'\s+(?:na\s+verdade|na\s+real)$').firstMatch(s);
    if (tail != null) {
      trailingMarker = true;
      s = s.substring(0, tail.start).trim();
    }
    // "na verdade o açougue foi 23", "aliás, a padaria foi 12": the marker
    // before a record named by its own noun phrase corrects *that* record —
    // it rewrote the last one instead (CHAOS-B-013).
    final marker = _correctionLead.firstMatch(s);
    final saysCorrection = marker != null || trailingMarker;
    if (marker != null) s = s.substring(marker.end).replaceFirst(_lead, '').trim();
    if (s.isEmpty) return null;

    for (final v in _entryVerb.allMatches(s)) {
      // "aquele que eu paguei 50 foi no crédito": the verb names the record.
      if (!RegExp(r'\bque\s+(?:eu\s+|a\s+gente\s+)?(?:\w+\s+)?$').hasMatch(s.substring(0, v.start))) return null;
    }

    var explicit = false;
    // "(tá) errado", "na verdade", "agora é", "era": the sentence corrects.
    if (RegExp(r'\b(?:ta|esta|tava)\s+errad[oa]\b|\berrad[oa]\b').hasMatch(s)) {
      explicit = true;
      s = s.replaceAll(RegExp(r'\b(?:ta|esta|tava)?\s*errad[oa]\b'), ' ');
    }
    if (saysCorrection || RegExp(r'\b(?:na\s+verdade|na\s+real|agora|era|aquel[ea]s?|daquel[ea])\b').hasMatch(s)) explicit = true;

    // What it was NOT: "…e não 45", "nem era 150", "não no crédito".
    double? oldAmount;
    final negated = RegExp(r'\b(?:nao|nem)\s+(?:(?:e|era|foi|eh|seria)\s+)?(?:(?:um|uma|o|a|no|na|em|de|do|da|pra)\s+)?(\d+(?:[.,]\d+)?|[a-z]+(?:\s+de\s+[a-z]+)?)');
    for (final m in negated.allMatches(s)) {
      explicit = true;
      final v = RegExp(r'^\d').hasMatch(m.group(1)!) ? double.tryParse(m.group(1)!.replaceAll(',', '.')) : null;
      oldAmount ??= v;
    }
    s = s.replaceAll(negated, ' ').replaceAll(RegExp(r'\s+e\s*$'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

    String? refPart;
    String? changePart;
    var noDeterminer = false;
    final direct = RegExp('^($_determiner\\b.*?)\\s+$_softeners$_copula\\s+(.+)\$').firstMatch(s);
    if (direct != null) {
      refPart = direct.group(1)!;
      changePart = direct.group(2)!;
    } else {
      // Inverted: "foi 26 o 99 de hoje", "era 140 o posto".
      final inv = RegExp('^$_softeners$_copula\\s+(.+?)\\s+($_determiner\\s+.+)\$').firstMatch(s);
      if (inv != null) {
        changePart = inv.group(1)!;
        refPart = inv.group(2)!;
      } else {
        // "hamburgueria do domingo na real deu 58": no article, but the
        // correction marker right before the copula says it corrects the
        // record named before it (ACC-C-008).
        final bare = RegExp('^([a-z][a-z0-9 ]*?)\\s+(?:na\\s+verdade|na\\s+real)\\s+$_copula\\s+(.+)\$').firstMatch(s);
        if (bare != null && bare.group(1)!.split(' ').length <= 5) {
          refPart = 'o ${bare.group(1)!}';
          changePart = bare.group(2)!;
          noDeterminer = true;
        }
      }
    }
    if (refPart == null || changePart == null) return null;
    // "o açougue lá da quinta passada": place fillers aren't part of the name.
    refPart = refPart.replaceAll(RegExp(r'\s+(?:la|ali|aqui|ai)\b'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    // "saiu por 90", "foi de 90", "ficou em 90": the preposition of the value.
    changePart = changePart.replaceFirst(RegExp(r'^(?:por|de|em)\s+(?=(?:r\$\s*)?\d)'), '');
    // The reference must name something besides the article.
    final content = refPart.replaceFirst(RegExp('^$_determiner\\s*'), '').replaceAll(RegExp(r'\b(?:lancamento|registro|gasto|de|do|da)\b'), ' ').trim();
    if (content.isEmpty) return null;
    // A pronoun alone ("esse", "isso") is the last record — other rules own it.
    if (RegExp(r'^(?:esse|essa|este|esta|isso|isto)$').hasMatch(refPart.trim())) return null;
    // A change about a copula of another kind ("o posto tava cheio").
    if (RegExp(r'^(?:o|a|os|as)\s+(?:dia|tempo|jogo|filme|show|festa)\b').hasMatch(refPart)) return null;

    // A unit price ("a gasolina tá 6 o litro", "o pão foi 1,50 cada") talks
    // about prices, not about the value of a record.
    if (RegExp(r'\b(?:cada|(?:o|a|por|pela|pelo)\s+(?:litro|quilo|kg|unidade|metro|hora|dia|pessoa|cabeca))\b').hasMatch(changePart)) return null;
    // "o do posto foi pra encher o tanque da minha mãe, foi no pix": the new
    // field is in the last clause; what comes before it is just context.
    if (_leftoverContent(changePart, budgets).isNotEmpty) {
      final clauses = RegExp('(?:^|[,;]\\s*|\\s)$_copula\\s+').allMatches(changePart).toList();
      if (clauses.isNotEmpty) {
        final tail = changePart.substring(clauses.last.end).trim();
        if (tail.isNotEmpty && _leftoverContent(tail, budgets).isEmpty) changePart = tail;
      }
    }
    final changes = TransactionCommandParser.parseChanges(changePart, now: now, budgets: budgets, originalText: raw);
    if (changes.isEmpty) return null;
    // A verbless sentence never renames: "o mercado tá caro demais hoje em
    // dia" used to rename "Supermercado Carrefour" to "Caro demais dia" (and
    // move its date). Renaming needs an explicit "renomeia"/"chama de".
    if (changes.title != null) return null;
    // The predicate must be *only* field material (value, payment, installments,
    // date, category, type). Any other content word left over means it's a
    // remark about the thing ("caro demais", "lotado", "uma delícia"), not a
    // new value for the record.
    if (_leftoverContent(changePart, budgets).isNotEmpty) return null;
    // A date alone must be the whole predicate ("foi ontem", "era de terça");
    // "tava lotado hoje" only says when something else happened.
    final onlyDate = changes.date != null && changes.amount == null && changes.paymentMethod == null && changes.installments == null &&
        changes.type == null && changes.category == null;
    if (onlyDate &&
        changePart
            .replaceAll(RegExp(r'\b(?:hoje|ontem|anteontem|ante\s+ontem|semana\s+passada|dia\s+\d{1,2}|\d{1,2}/\d{1,2}|segunda|terca|quarta|quinta|sexta|sabado|domingo|feira|de|do|da|no|na|em|o|a|mesmo|na\s+verdade)\b'), ' ')
            .trim()
            .isNotEmpty) {
      return null;
    }
    final onlyCategory = changes.amount == null && changes.date == null && changes.type == null && changes.paymentMethod == null &&
        changes.installments == null;
    if (onlyCategory) {
      // "o uber foi caro" is an opinion, not a category: a verbless category
      // change must name a category itself ("o uber foi lazer").
      final said = CesarText.simplify(changePart).replaceAll(RegExp(r'^(?:(?:em|no|na|pra|para|de|da|do)\s+)+'), '').trim();
      final names = CesarText.categoryWords.containsKey(said) || budgets.any((b) => CesarText.fold(b.name) == said);
      if (!names) return null;
    }
    return ReferenceEdit(refPart, changes,
        oldAmount: oldAmount, explicitCorrection: explicit || noDeterminer, namesRecordAfterMarker: saysCorrection || noDeterminer);
  }

  /// Words a field value can be made of; whatever is left after removing them
  /// from a predicate is content the edit would otherwise silently absorb.
  static final RegExp _fieldWords = RegExp(
    r'\b(?:'
    // value
    r'r\$|\d+(?:[.,]\d+)*|reais|real|conto|contos|pila|pilas|mil|centavos?|'
    // payment and installments
    r'pix|pics|debito|credito|cartao|dinheiro|especie|boleto|bancario|a\s+vista|vista|\d*x|vezes|parcelas?|parcelado|parcelada|'
    // date
    r'hoje|ontem|anteontem|ante\s+ontem|semana|passada|passado|mes|dia|segunda|terca|quarta|quinta|sexta|sabado|domingo|feira|'
    r'esse|essa|este|esta|nesse|nessa|neste|nesta|desse|dessa|deste|desta|ultimo|ultima|proximo|proxima|'
    r'janeiro|fevereiro|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro|'
    // type
    r'receita|despesa|entrada|saida|gasto|transferencia|renda|'
    // glue
    r'de|do|da|dos|das|no|na|nos|nas|em|o|a|os|as|um|uma|pra|para|com|e|ou|mesmo|agora|na\s+verdade|na\s+real|so|ja|tambem|eh|ta|foi|era'
    r')\b',
  );

  static String _leftoverContent(String changePart, List<BudgetCategory> budgets) {
    var rest = CesarText.simplify(changePart);
    for (final word in CesarText.categoryWords.keys) {
      rest = rest.replaceAll(RegExp('\\b${RegExp.escape(word)}\\b'), ' ');
    }
    for (final b in budgets) {
      final name = CesarText.fold(b.name);
      if (name.isNotEmpty) rest = rest.replaceAll(RegExp('\\b${RegExp.escape(name)}\\b'), ' ');
    }
    return rest.replaceAll(_fieldWords, ' ').replaceAll(RegExp(r'[^a-z]+'), ' ').trim();
  }
}
