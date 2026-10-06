import '../backend/models/budget_category.dart';
import '../backend/models/financial_transaction.dart';
import 'cesar_text.dart';
import 'local_nlp_engine.dart';
import 'pt_number_words.dart';

/// Fields a chat correction can change on a saved transaction. Null = keep.
class TransactionChanges {
  final double? amount;
  final DateTime? date;
  final TransactionType? type;
  final String? category;
  final String? paymentMethod;
  final int? installments;
  final String? title;

  const TransactionChanges({this.amount, this.date, this.type, this.category, this.paymentMethod, this.installments, this.title});

  static const none = TransactionChanges();

  bool get isEmpty =>
      amount == null && date == null && type == null && category == null && paymentMethod == null && installments == null && title == null;

  @override
  String toString() =>
      'Changes(amount=$amount date=$date type=$type cat=$category pay=$paymentMethod inst=$installments title=$title)';
}

enum ChatCommandKind { delete, edit, showForEdit }

/// A request to change or remove saved transaction(s), before resolving which.
class ChatCommand {
  final ChatCommandKind kind;

  /// Words that identify the target ("o uber de ontem", "o anterior"); '' = the last one.
  final String reference;
  final TransactionChanges changes;

  /// Explicit command ("muda…", "apaga…", "na verdade…"): answer even when
  /// nothing could be applied. A weak one (verbless "o mercado de ontem foi
  /// no débito") only counts if its target exists and a change was understood.
  final bool strong;

  /// Set when the correction is itself a complete entry ("na verdade, hoje
  /// eu gastei 20 no pastel no pix"): the text without the correction
  /// marker. The assistant decides between a new entry and a correction of
  /// the last one, and asks when both fit (R2-CONV-001).
  final String? entryText;

  const ChatCommand(this.kind, {this.reference = '', this.changes = TransactionChanges.none, this.strong = true, this.entryText});

  @override
  String toString() => 'ChatCommand($kind, ref="$reference", $changes, strong=$strong, entry=$entryText)';
}

/// Understands free-language commands to edit, delete or undo transactions:
/// "não, foi 45", "ops era 45", "esse era lazer", "na verdade foi ontem",
/// "era receita", "muda o valor do aluguel pra 1500", "exclui o uber de
/// ontem", "apaga os dois últimos", "desfaz"… Pure and stateless; the
/// target is resolved later by [TransactionReferenceResolver].
///
/// It must never fire on an ordinary entry: "apaguei a luz e gastei 50",
/// "gastei 50 no mercado", "o mercado de ontem estava cheio, gastei 80" are
/// all new transactions (see `test/transaction_command_parser_test.dart`).
class TransactionCommandParser {
  TransactionCommandParser._();

  static final _politePrefix = RegExp(r'^(?:cesar\s+)?(?:(?:por\s+favor|pf|pfv|ei|oi)\s+)?(?:(?:voce|vc|tu)\s+)?(?:pode|poderia|podia|consegue|da\s+pra)\s+');
  static final _politeSuffix = RegExp(r'\s+(?:por\s+favor|pf|pfv|pra\s+mim|cesar)$');

  static String _clean(String text) {
    // A vocative before the command ("ô césar, muda…", "e aí césar apaga…")
    // is not part of it (ACC-B-016).
    var s = CesarText.simplify(text).replaceFirst(RegExp(r'^(?:(?:o|oh|ow|oi|ei|e\s+ai|eai|ae|fala)\s+)?cesar\s+'), '');
    // Interjections before the command ("ah, e foi ontem", "putz, apaga o
    // uber") don't change it (R2-CONV-021).
    s = s.replaceFirst(RegExp(r'^(?:(?:ah|ahn|hum|hmm|eita|poxa|putz|nossa|ixi|vixe|olha|pera|peraí|perai)\s+)+'), '');
    s = s.replaceFirst(_politePrefix, '').replaceFirst(_politeSuffix, '');
    return s.trim();
  }

  /// "desfaz", "desfazer", "volta atrás", "não era pra apagar, volta", "ctrl z".
  static bool isUndo(String text) {
    final s = _clean(text);
    if (RegExp(r'\b(?:nao|nem)\s+(?:\w+\s+)?(?:desfaz\w*|volt\w*)\b').hasMatch(s)) return false;
    return RegExp(r'^(?:desfaz|desfazer|desfaca|desfaz\s+isso|desfaz\s+o\s+que\s+(?:voce|vc)\s+fez|desfaz\s+(?:a\s+)?ultima\s+(?:acao|coisa|alteracao|mudanca))$').hasMatch(s) ||
        RegExp(r'^(?:volta|voltar)\s+atras\b|^(?:reverte|reverter|reverta)\b|^ctrl\s*z$|^undo$').hasMatch(s) ||
        RegExp(r'^nao\s+era\s+(?:isso|pra\s+(?:apagar|excluir|mudar|fazer\s+isso|ter\s+\w+))(?:\s+volta(?:\s+atras)?|\s+desfaz)?$').hasMatch(s) ||
        RegExp(r'\b(?:desfaz|desfazer|desfaca)\b').hasMatch(s) && s.split(' ').length <= 8 && !RegExp(r'\d').hasMatch(s);
  }

  static const deleteVerbs = _deleteVerbs;
  static const _deleteVerbs =
      r'apaga|apague|apagar|exclui|exclua|excluir|deleta|delete|deletar|remove|remova|remover|descarta|descarte|cancela|cancele|cancelar|desconsidera|desconsidere|tira|tire|'
      // Colloquial: "joga fora a feira", "some com o do 99", "sumir com aquele".
      r'joga\s+fora|jogue\s+fora|jogar\s+fora|some\s+com|suma\s+com|sumir\s+com|elimina|elimine|eliminar|risca|risque|'
      // "joga no lixo o lava-rápido", "manda pro lixo aquele" (ACC-B-016).
      r'(?:joga|jogue|jogar|manda|mande|mandar|bota|bote|coloca|coloque)\s+(?:no|pro|para\s+o|pra)\s+lixo';
  static const _editVerbs =
      r'muda|mude|mudar|altera|altere|alterar|troca|troque|trocar|corrige|corrija|corrigir|conserta|arruma|arrume|edita|edite|editar|'
      r'atualiza|atualize|renomeia|renomeie|renomear|coloca|coloque|poe|bota|passa|passe|move|mova|joga|'
      // "ajusta a hamburgueria pra 55", "aumenta a floricultura pra 100"
      // (ACC-C-009): only with "pra N" — the new value, not an increment.
      r'ajusta|ajuste|ajustar|reajusta|reajuste|reajustar|aumenta|aumente|aumentar|diminui|diminua|diminuir|reduz|reduza|reduzir|abaixa|abaixe|sobe|suba';

  static final _changeToValueVerb = RegExp(r'^(?:ajust|reajust|aument|diminu|reduz|abaix|sob|sub)');

  // ── "is this sentence itself an entry?" ──
  static final _entryVerb = RegExp(
    r'\b(?:gastei|gastamos|paguei|pagamos|comprei|compramos|recebi|recebemos|transferi|ganhei|torrei|larguei|desembolsei|pedi|'
    r'almocei|jantei|lanchei|abasteci|depositei|mandei|investi|quitei|tomei|comi|bebi)\b',
  );
  static final _paymentWord = RegExp(r'\b(?:pix|credito|debito|dinheiro|boleto|cartao|especie|a\s+vista|\d{1,2}\s*x)\b');
  static final _placePhrase = RegExp(r'\b(?:no|na|nos|nas|num|numa|em|com|de|do|da|pro|pra|pelo|pela)\s+(?:(?:o|a|um|uma)\s+)?([a-z]{3,})');
  static const _notAPlace = {
    'hoje', 'ontem', 'anteontem', 'reais', 'real', 'conto', 'contos', 'pila', 'pilas', 'mim', 'ele', 'ela', 'voce', 'novo', 'nova',
    'volta', 'vez', 'verdade', 'manha', 'tarde', 'noite', 'semana', 'mes', 'dia', 'valor', 'total', 'mais', 'menos',
  };

  /// A sentence that is a whole entry on its own — an entry verb in the main
  /// clause, a value after it and where/how it was paid ("gastei 20 no pastel
  /// no pix", "pedi uma pizza de 65 no pix"). Such a sentence is a new entry,
  /// never a command: "excluí o app mas pedi uma pizza de 65 no pix" was read
  /// as "delete" (R2-CONV-009). An entry verb inside a relative clause refers
  /// to an old record instead ("apaga o mercado que eu paguei 50 no pix").
  static bool looksLikeFullEntry(String text) {
    final s = PtNumberWords.normalize(CesarText.simplify(text));
    for (final v in _entryVerb.allMatches(s)) {
      if (RegExp(r'\bque\s+(?:eu\s+|a\s+gente\s+)?(?:\w+\s+)?$').hasMatch(s.substring(0, v.start))) continue;
      final after = s.substring(v.end);
      if (!RegExp(r'\d').hasMatch(after)) continue;
      if (_paymentWord.hasMatch(after)) return true;
      if (_placePhrase.allMatches(after).any((m) => !_notAPlace.contains(m.group(1)))) return true;
    }
    return false;
  }

  /// Other features own these words ("apaga a categoria pets", "tira 50 da meta").
  static final _otherDomains = RegExp(r'\b(?:categorias?\s+(?!pra\b|para\b)\w+\s+(?:pra|para)\b|meta|metas|orcamento|orcamentos|limite|limites|lembrete|lembretes)\b');

  /// Parses an edit/delete command. [now] anchors relative dates; [budgets]
  /// names the categories. Returns null when [text] isn't one.
  static ChatCommand? parse(String text, {required DateTime now, required List<BudgetCategory> budgets}) {
    final raw = text.trim();
    if (raw.isEmpty) return null;
    final s = _clean(raw);
    final asksPolitely = _politePrefix.hasMatch(CesarText.simplify(raw).replaceFirst(RegExp(r'^cesar\s+'), ''));
    if (raw.endsWith('?') && !asksPolitely) return null;

    // ── delete ──
    final del = RegExp('^($_deleteVerbs)\\b\\s*(.*)\$').firstMatch(s);
    if (del != null) {
      final verb = del.group(1)!;
      final rest = del.group(2)!.trim().replaceFirst(RegExp(r'^(?:ai|ae|la|aqui|pra\s+mim)\s+(?=(?:o|a|os|as|esse|essa|aquele|aquela|do|da)\b)'), '');
      // "excluí o app…" (past, with the accent) tells what happened; and a
      // complete entry in the sentence makes it an entry, not a command.
      if (raw.toLowerCase().trimLeft().startsWith('excluí')) return null;
      if (looksLikeFullEntry(rest)) return null;
      if (RegExp(r'\b(?:categorias?|metas?|orcamentos?|limites?|lembretes?)\b').hasMatch(rest)) return null;
      // "desconsidera o valor, foi no débito": drops a field, not the record.
      if (RegExp(r'^(?:o|a|esse|essa)\s+(?:valor|categoria|forma|pagamento|data|parcelas?|descricao)\b').hasMatch(rest)) return null;
      // "tira 50 da conta" is not a delete; "tira o uber" and "tira aquele
      // de 62,30" are: right after the verb comes a record, not a value.
      if (verb.startsWith('tir') && !RegExp(r'^(?:o|a|os|as|esse|essa|isso|este|esta|aquele|aquela|aqueles|aquelas)\b').hasMatch(rest)) {
        return null;
      }
      return ChatCommand(ChatCommandKind.delete, reference: rest);
    }

    // ── edit with a verb ──
    final ed = RegExp('^($_editVerbs)\\b\\s*(.*)\$').firstMatch(s);
    if (ed != null) {
      final verb = ed.group(1)!;
      // "muda aí o açougue…", "troca lá a padaria…": filler after the verb.
      final rest = ed.group(2)!.trim().replaceFirst(RegExp(r'^(?:ai|ae|la|aqui|pra\s+mim)\s+(?=(?:o|a|os|as|esse|essa|aquele|aquela|do|da)\b)'), '');
      // "aumenta 50 no aluguel" adds, it doesn't set: only "… pra N" edits.
      if (_changeToValueVerb.hasMatch(verb) && !RegExp(r'\s(?:pra|para)\s+(?:r\$\s*)?\d[\d.,]*(?:\s*(?:reais|real|conto|contos))?$').hasMatch(' $rest')) {
        return null;
      }
      if (_otherDomains.hasMatch(rest) || RegExp(r'\bnome\s+da\s+categoria\b').hasMatch(rest)) return null;
      if (verb.startsWith('renome') && RegExp(r'\bcategoria\b').hasMatch(rest)) return null;
      if (looksLikeFullEntry(rest)) return null; // "troca de óleo, paguei 150 no pix"
      final placeVerb = RegExp(r'^(?:coloca|coloque|poe|bota|passa|passe|move|mova|joga)$').hasMatch(verb);
      // "coloca 50 de gasolina", "passa 100 pro joão": new entries, not edits
      // — but "passa o táxi de sábado pra 30" names a record (an article, no
      // value) and then its new value: an edit (ACC-A-015).
      if (placeVerb && RegExp(r'\d').hasMatch(rest) && !RegExp(r'\b\d{1,2}\s*(?:x|vezes|parcelas)\b').hasMatch(rest)) {
        // "bota a drogaria de quinta como 52" too (ACC-B-016). A number right
        // after the article is a name — "passa o 99 pra 25" edits the "99"
        // (CHAOS-B-016); "passa 99 pro joão" stays a transfer.
        final toValue = RegExp(r'^((?:o|a|os|as|esse|essa|aquele|aquela)\s+(?:[a-z]|\d+\b(?!\s*(?:reais|real|conto|contos)\b)).*?)\s(?:pra|para|pro|como)\s+(?:r\$\s*)?\d[\d.,]*(?:\s*(?:reais|real|conto|contos))?$')
            .firstMatch(rest);
        if (toValue == null) return null;
        final named = toValue.group(1)!.replaceFirst(RegExp(r'^(?:o|a|os|as|esse|essa|aquele|aquela)\s+(?:d[oa]\s+)?\d+\b'), ' ');
        if (RegExp(r'\d').hasMatch(named)) return null;
      }

      final padded = ' $rest ';
      // "o açougue da sexta que foi 86 na verdade": the clause "que foi N"
      // brings the new value (ACC-B-016).
      var split = RegExp(r'\s(?:pra|para|pro|por|p|como|que\s+(?:foi|era|eh|e|custou|deu|saiu|ficou))\s').allMatches(padded).toList();
      if (split.isEmpty && placeVerb) split = RegExp(r'\s(?:em|no|na)\s').allMatches(padded).toList();
      if (split.isEmpty) {
        if (rest.isEmpty || RegExp(r'^(?:o|a|esse|essa|este|esta|isso|meu|minha)?\s*(?:ultimo|ultima|lancamento|registro|anterior|penultimo)\b').hasMatch(rest) ||
            verb.startsWith('edit')) {
          // "corrige 45" / "muda 45" — no connector, but a value.
          final direct = parseChanges(rest, now: now, budgets: budgets);
          if (!verb.startsWith('edit') && !direct.isEmpty && rest.split(' ').length <= 4) {
            return ChatCommand(ChatCommandKind.edit, changes: direct);
          }
          return ChatCommand(ChatCommandKind.showForEdit, reference: rest);
        }
        final direct = parseChanges(rest, now: now, budgets: budgets);
        return ChatCommand(ChatCommandKind.edit, changes: direct);
      }
      final cut = split.last;
      var refPart = padded.substring(0, cut.start).trim();
      final changePart = padded.substring(cut.end).trim();

      String? field;
      final fm = RegExp(r'^(?:o\s+|a\s+)?(valor|preco|categoria|forma\s+de\s+pagamento|pagamento|meio\s+de\s+pagamento|data|dia|nome|descricao|titulo|tipo)\b\s*(?:d[oa]s?\b\s*|de\b\s*)?')
          .firstMatch(refPart);
      if (fm != null) {
        field = fm.group(1)!;
        refPart = refPart.substring(fm.end).trim();
      }
      if (verb.startsWith('renome')) field = 'nome';

      var changes = parseChanges(changePart, now: now, budgets: budgets, field: field, originalText: raw);
      if (field == 'nome' || field == 'descricao' || field == 'titulo') {
        final title = RegExp(r'\s(?:pra|para)\s+(.+?)\s*[.!]*$', caseSensitive: false).allMatches(' $raw').lastOrNull?.group(1);
        if (title != null && title.trim().isNotEmpty) {
          final t = title.trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
          changes = TransactionChanges(title: t[0].toUpperCase() + t.substring(1));
        }
      }
      return ChatCommand(ChatCommandKind.edit, reference: refPart, changes: changes);
    }

    // ── correction markers: the last transaction ──
    final mk = RegExp(r'^(na\s+verdade|na\s+real|na\s+vdd|nvdd|alias|opa|ops|epa|errei|me\s+enganei|foi\s+mal|corrigindo|correcao|'
            r'o\s+valor\s+(?:certo|correto)\s+(?:e|era|foi)|o\s+(?:certo|correto)\s+(?:e|era|foi)|valor\s+(?:certo|correto)\s+(?:e|era)?|o\s+valor\s+(?:e|era|foi)|'
            r'nao|e\s+foi|e\s+era|mas\s+foi|mas\s+era|era|foi|esse|essa|este|esta|isso|isto)\b\s*(.*)$')
        .firstMatch(s);
    if (mk != null) {
      final marker = mk.group(1)!;
      var rest = mk.group(2)!.trim();
      final demonstrative = RegExp(r'^(?:esse|essa|este|esta|isso|isto)$').hasMatch(marker);
      if (demonstrative) {
        final m = RegExp(r'^(?:lancamento\s+|gasto\s+|valor\s+)?(?:era|foi|e|eh|fica|ficou|ta|tava|vai|entra|pertence|na\s+verdade\s+(?:e|era|foi))\b\s*(.*)$').firstMatch(rest);
        if (m == null) return null;
        rest = m.group(1)!;
      }
      if (marker == 'nao' && !RegExp(r'^(?:foi|era|e|eh|na\s+verdade|o\s+valor|a\s+categoria|errei|e\s+\w+)\b').hasMatch(rest)) return null;
      if (rest.isEmpty) return null;
      // "e 30 na padaria" / "foi 50 no mercado no pix e 30…" are entries.
      if (RegExp(r'\b(?:gastei|paguei|comprei|recebi|transferi)\b').hasMatch(rest) && RegExp(r'\be\s+\d').hasMatch(rest)) return null;
      // "na verdade o 7 belo foi 15": the change is what comes after the
      // copula — a number in the name is not the new value (CHAOS-C-005).
      final named = RegExp(r'^(?:o|a|os|as)\s+.+?\s+(?:foi|era|deu|custou|saiu|ficou|eh)\s+(.+)$').firstMatch(rest);
      final fragment = marker == 'nao' ? CesarText.fold(raw) : (named?.group(1) ?? rest);
      final changes = parseChanges(fragment, now: now, budgets: budgets, originalText: raw);
      final strong = RegExp(r'^(?:na\s+verdade|na\s+real|errei|me\s+enganei|corrigindo|correcao|o\s+valor|o\s+certo|o\s+correto|valor)').hasMatch(marker);
      // "na verdade, hoje eu gastei 20 no pastel no pix": a complete entry
      // after the marker may be a new one — the assistant decides (R2-CONV-001).
      if (looksLikeFullEntry(rest)) {
        return ChatCommand(ChatCommandKind.edit, changes: changes, strong: true, entryText: stripCorrectionMarker(raw));
      }
      if (changes.isEmpty && !strong) return null;
      return ChatCommand(ChatCommandKind.edit, changes: changes, strong: strong);
    }

    // ── verbless edit of an older record: "o mercado de ontem foi no débito" ──
    final vb = RegExp(r'^(?:o|a)\s+(.+?)\s+(?:foi|era|e|eh)\s+(.+)$').firstMatch(s);
    if (vb != null && !RegExp(r'\b(?:estava|tava|gastei|paguei|comprei|recebi|custou|deu|saiu)\b').hasMatch(s)) {
      final ref = vb.group(1)!;
      final qualified = RegExp(r'\b(?:ontem|anteontem|hoje|dia\s+\d{1,2}|segunda|terca|quarta|quinta|sexta|sabado|domingo|semana\s+passada|ultimo|anterior)\b').hasMatch(ref);
      final changes = parseChanges(vb.group(2)!, now: now, budgets: budgets, originalText: raw);
      // An amount here is a new entry ("o almoço de ontem foi 45").
      if (qualified && !changes.isEmpty && changes.amount == null) {
        return ChatCommand(ChatCommandKind.edit, reference: ref, changes: changes, strong: false);
      }
    }
    return null;
  }

  /// A delete/edit command that names a record other than "the last one"
  /// ("apaga o do sacolão", "exclui os dois", "muda o uber pra 30"). With a
  /// draft still pending, such a command is about that record — not a
  /// "cancel" of the draft (R2-CONV-007).
  static bool namesSpecificRecord(String text, {required DateTime now, required List<BudgetCategory> budgets}) {
    final cmd = parse(text, now: now, budgets: budgets);
    if (cmd == null || cmd.reference.trim().isEmpty) return false;
    final ref = CesarText.simplify(cmd.reference);
    // "apaga isso", "cancela esse lançamento", "apaga tudo": the draft itself.
    return !RegExp(r'^(?:(?:o|a|esse|essa|este|esta|isso|isto|ele|ela|tudo|ai|la|aqui|agora|mesmo|lancamento|registro|rascunho|gasto|ultimo|ultima|entao|anterior|penultimo|penultima)(?:\s+|$))+$')
        .hasMatch('$ref ');
  }

  /// [raw] without a leading "na verdade,", "ops", "aliás"…, keeping its
  /// original spelling (accents) for the entry that follows.
  static String stripCorrectionMarker(String raw) {
    final stripped = raw.trimLeft().replaceFirst(
        RegExp(r'^(?:na\s+verdade|na\s+real|ali[aá]s|opa|ops|epa|errei|me\s+enganei|foi\s+mal|corrigindo|corre[cç][aã]o|n[aã]o|e\s+foi|mas\s+foi)\b[\s,:;.!-]*',
            caseSensitive: false),
        '');
    return stripped.isEmpty ? raw.trim() : stripped;
  }

  static const _weekdays = {
    'segunda': DateTime.monday, 'terca': DateTime.tuesday, 'quarta': DateTime.wednesday, 'quinta': DateTime.thursday,
    'sexta': DateTime.friday, 'sabado': DateTime.saturday, 'domingo': DateTime.sunday,
  };

  /// Names of categories themselves — "é lazer" changes only the category.
  /// Any other word that resolves to a category ("foi farmácia", "foi no
  /// uber") names a place/item, so the title changes to it too.
  static const _categoryNameWords = {
    'lazer', 'alimentacao', 'transporte', 'saude', 'moradia', 'casa', 'contas', 'educacao', 'investimento', 'investimentos',
    'salario', 'outros', 'outras despesas', 'combustivel',
  };

  /// Reads the changes named in [fragment]: value, date, type, category,
  /// payment method, installments. [field] ("valor", "categoria", "data"…)
  /// restricts the reading when the user named what to change.
  static TransactionChanges parseChanges(String fragment,
      {required DateTime now, required List<BudgetCategory> budgets, String? field, String? originalText}) {
    // Negated parts are what it was NOT: "não é mercado, é farmácia", "era
    // receita, não gasto". Spoken "não foi 45" has no comma and is the
    // correction itself — if dropping the negated part leaves nothing, read
    // the whole fragment instead.
    final folded = CesarText.fold(fragment);
    final withoutNegated = folded.replaceAll(
        RegExp(r'\b(?:nao|nem)\s+(?:(?:e|era|foi|eh|seria)\s+)?(?:(?:um|uma|o|a|no|na|em|de|do|da|pra)\s+)?(?:[a-z]+(?:\s+de\s+[a-z]+)?|\d+(?:[.,]\d+)?)'), ' ');
    final original = originalText ?? fragment;
    final result = _readChanges(withoutNegated, now: now, budgets: budgets, field: field, originalText: original);
    if (!result.isEmpty || withoutNegated == folded) return result;
    return _readChanges(folded, now: now, budgets: budgets, field: field, originalText: original);
  }

  static TransactionChanges _readChanges(String text,
      {required DateTime now, required List<BudgetCategory> budgets, String? field, required String originalText}) {
    var f = PtNumberWords.normalize(text);
    f = f.replaceAll(RegExp(r'[!?;:"()]'), ' ').replaceAll(RegExp(r'(?<!\d)[.,]|[.,](?!\d)'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final today = CesarText.dayOnly(now);
    final only = field == null ? null : _fieldKind(field);

    int? installments;
    final inst = RegExp(r'\b(?:em\s+)?(\d{1,2})\s*(?:x|vezes|parcelas?)\b').firstMatch(f);
    if (inst != null && (only == null || only == 'payment')) {
      installments = int.parse(inst.group(1)!);
      f = f.replaceFirst(inst.group(0)!, ' ');
    } else if (RegExp(r'\ba\s+vista\b').hasMatch(f) && (only == null || only == 'payment')) {
      installments = 1;
      f = f.replaceFirst(RegExp(r'\ba\s+vista\b'), ' ');
    }

    String? payment;
    if (only == null || only == 'payment') {
      const pays = {
        r'\b(?:no\s+|via\s+|por\s+|de\s+)?(?:pix|pics|pixx)\b': 'pix',
        r'\b(?:no\s+)?(?:cartao\s+de\s+)?debito\b': 'debit_card',
        r'\b(?:no\s+)?(?:cartao\s+de\s+)?credito\b|\bno\s+cartao\b|^cartao$': 'credit_card',
        r'\b(?:em\s+|no\s+)?(?:dinheiro|especie|cash)\b': 'cash',
        r'\b(?:no\s+|via\s+)?boleto\b': 'bank_slip',
      };
      for (final e in pays.entries) {
        final m = RegExp(e.key).firstMatch(f);
        if (m != null) {
          payment = e.value;
          f = f.replaceFirst(m.group(0)!, ' ');
          break;
        }
      }
      if (payment == null && installments != null && installments > 1) payment = 'credit_card';
    }

    DateTime? date;
    if (only == null || only == 'date') {
      void setDate(DateTime d, String matched) {
        date = d;
        f = f.replaceFirst(matched, ' ');
      }

      final dm = RegExp(r'\b(\d{1,2})/(\d{1,2})\b').firstMatch(f);
      final dn = RegExp(r'\b(?:dia\s+|no\s+dia\s+)(\d{1,2})\b').firstMatch(f);
      final wd = RegExp(r'\b(?:na\s+|no\s+)?(segunda|terca|quarta|quinta|sexta|sabado|domingo)(?:\s+feira)?\b').firstMatch(f);
      final ante = RegExp(r'\bante\s*-?\s*ontem\b').firstMatch(f);
      if (ante != null) {
        setDate(today.subtract(const Duration(days: 2)), ante.group(0)!);
      } else if (RegExp(r'\bontem\b').hasMatch(f)) {
        setDate(today.subtract(const Duration(days: 1)), 'ontem');
      } else if (RegExp(r'\bhoje\b').hasMatch(f)) {
        setDate(today, 'hoje');
      } else if (RegExp(r'\bsemana\s+passada\b').hasMatch(f)) {
        setDate(today.subtract(const Duration(days: 7)), 'semana passada');
      } else if (dm != null) {
        setDate(DateTime(now.year, int.parse(dm.group(2)!), int.parse(dm.group(1)!)), dm.group(0)!);
      } else if (dn != null) {
        final n = int.parse(dn.group(1)!);
        var d = DateTime(now.year, now.month, n);
        if (d.isAfter(today)) d = DateTime(now.year, now.month - 1, n);
        setDate(d, dn.group(0)!);
      } else if (wd != null) {
        var back = (today.weekday - _weekdays[wd.group(1)!]!) % 7;
        if (back == 0) back = 7;
        setDate(today.subtract(Duration(days: back)), wd.group(0)!);
      } else if (only == 'date') {
        final bare = RegExp(r'\b(\d{1,2})\b').firstMatch(f);
        if (bare != null) {
          final n = int.parse(bare.group(1)!);
          var d = DateTime(now.year, now.month, n);
          if (d.isAfter(today)) d = DateTime(now.year, now.month - 1, n);
          setDate(d, bare.group(0)!);
        }
      }
    }

    TransactionType? type;
    if (only == null || only == 'type') {
      final inc = RegExp(r'\b(?:uma\s+|um\s+)?(?:receita|entrada|ganho|recebimento|renda|credito\s+em\s+conta)\b').firstMatch(f);
      final exp = RegExp(r'\b(?:uma\s+|um\s+)?(?:despesa|gasto|saida)\b').firstMatch(f);
      final trf = RegExp(r'\b(?:uma\s+)?transferencia\b').firstMatch(f);
      final m = inc ?? trf ?? exp;
      if (m != null) {
        type = inc != null ? TransactionType.income : (trf != null ? TransactionType.transfer : TransactionType.expense);
        f = f.replaceFirst(m.group(0)!, ' ');
      }
    }

    double? amount;
    if (only == null || only == 'amount') {
      final am = RegExp(r'(?:r\$\s*)?(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)\s*(mil|k)?\b').firstMatch(f);
      if (am != null) {
        var v = LocalFinancialNlpEngine.cleanAndParseAmount(am.group(1));
        if (v != null && am.group(2) != null) v *= 1000;
        if (v != null && v > 0 && v.isFinite) amount = v;
        f = f.replaceFirst(am.group(0)!, ' ');
      }
    }

    String? category;
    String? title;
    if (only == null || only == 'category') {
      final leftover = f
          .replaceAll(RegExp(r'\b(?:na\s+verdade|na\s+real|foi|era|e|eh|e\s+foi|seria|fica|ficou|entra|pertence|a|o|um|uma|no|na|em|pra|para|pro|de|do|da|'
              r'categoria|na\s+categoria|valor|reais|real|conto|contos|mas|so|isso|esse|essa|ops|opa|errei|nao|sim|ta|tava|lancamento|coloca|coloque|como)\b'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (leftover.isNotEmpty && leftover.split(' ').length <= 4 && !RegExp(r'\d').hasMatch(leftover)) {
        category = CesarText.resolveCategory(leftover, budgets);
        if (category != null && only == null && !_categoryNameWords.contains(leftover) &&
            !budgets.any((b) => CesarText.fold(b.name) == leftover || (b.isCustom && CesarText.resolveCategory(leftover, [b]) == b.category))) {
          final spelled = _originalSpelling(leftover, originalText);
          title = spelled[0].toUpperCase() + spelled.substring(1);
        }
      }
    }

    return TransactionChanges(
      amount: amount,
      date: date,
      type: type,
      category: category,
      paymentMethod: payment,
      installments: installments,
      title: title,
    );
  }

  /// The substring of [original] that folds to [folded] ("farmácia" for "farmacia").
  static String _originalSpelling(String folded, String original) {
    final lower = original.toLowerCase();
    for (var i = 0; i + folded.length <= lower.length; i++) {
      if (CesarText.fold(lower.substring(i, i + folded.length)) == folded) return lower.substring(i, i + folded.length);
    }
    return folded;
  }

  static String _fieldKind(String field) {
    if (field.startsWith('valor') || field.startsWith('preco')) return 'amount';
    if (field.contains('pagamento')) return 'payment';
    if (field == 'data' || field == 'dia') return 'date';
    if (field == 'categoria') return 'category';
    if (field == 'tipo') return 'type';
    return 'title';
  }
}
