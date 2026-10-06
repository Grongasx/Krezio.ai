import 'category_name_matcher.dart';
import 'hypothesis_detector.dart';
import 'pt_number_words.dart';
import 'transaction_command_parser.dart';

/// Why a message typed while César waits for an answer is **not** that
/// answer, but a subject of its own.
enum TopicShift {
  /// Nothing says it isn't the answer.
  none,

  /// A command about saved records: "apaga o sacolão", "muda o cinema de
  /// segunda pra 30", "desfaz".
  command,

  /// A question of its own: "quanto gastei hoje?".
  question,

  /// Something that didn't (or didn't yet) happen: "por pouco não torrei 118
  /// no cassino", "se eu comprar um tênis de 300…".
  nonEvent,

  /// An entry that tells its own story — its own money verb and another
  /// object, or the money going the other way: "gastei 30 na padaria no
  /// pix" while César asks what to change in the Mercado; "o síndico me
  /// cobrou 30 de multa" while he asks the value of the ração.
  newEntry,
}

/// What César is waiting on: the words said about it (a draft's turns and
/// description, or the title of the record being edited), and its
/// direction/category when known.
class PendingSubject {
  final String text;

  /// 'expense' | 'income' | 'transfer' (null = unknown).
  final String? direction;
  final String? category;

  /// A saved record (editing it), not a draft still being filled.
  final bool isRecord;

  const PendingSubject(this.text, {this.direction, this.category, this.isRecord = false});
}

/// The single "is this the answer, or a new subject?" check behind every
/// state in which César waits for the user (Portão do lote A, etapa 7d): a
/// draft missing its value/payment/category/date, a recurring bill, a batch,
/// "o que você quer mudar?", a "não achei — é esse?" suggestion, a choice
/// among several records. Before, each state had its own rule and some
/// accepted anything ("passa" ⏎ "gastei 30 na padaria" renamed the Mercado
/// to "Gastei padaria").
///
/// Structural, not a phrase list: a message leaves the pending state when it
/// is a **command** (verb + the record it names), a **question**, a
/// **non-event** (denied, hypothetical or planned), or an **entry with its own
/// story** — a money verb of its own whose object is not what César asked
/// about, or whose money goes the other way. A bare value, a payment, a date,
/// a place without a verb of its own stay answers. Pure Dart.
class PendingReplyCheck {
  PendingReplyCheck._();

  /// [text] against [subject]. [textDirection]/[textCategory]: how the engine
  /// read [text] on its own (null = not an entry/unknown). [now]/[commands]:
  /// when given, commands about saved records count as a shift (the draft
  /// flow handles them before asking this, so it doesn't pass them).
  static TopicShift classify(String text, PendingSubject subject,
      {String? textDirection, String? textCategory, bool commands = false, DateTime? now}) {
    final raw = text.trim();
    if (raw.isEmpty) return TopicShift.none;
    if (commands && isCommand(raw, now: now ?? DateTime.now())) return TopicShift.command;
    if (isNonEvent(raw)) return TopicShift.nonEvent;
    if (isQuestion(raw)) return TopicShift.question;
    if (tellsAnotherStory(raw, subject, textDirection: textDirection, textCategory: textCategory)) return TopicShift.newEntry;
    return TopicShift.none;
  }

  /// "apaga o sacolão", "muda o cinema de segunda pra 30", "desfaz": a
  /// command that names its own target (or undoes). "muda pra 45"/"corrige
  /// 45" without a target is a change for the record being edited.
  static bool isCommand(String text, {required DateTime now}) {
    if (TransactionCommandParser.isUndo(text)) return true;
    final cmd = TransactionCommandParser.parse(text, now: now, budgets: const []);
    if (cmd == null) return false;
    if (cmd.kind == ChatCommandKind.delete) return true;
    return TransactionCommandParser.namesSpecificRecord(text, now: now, budgets: const []);
  }

  /// A question of its own: ends with "?" and is not an echoed value ("50?").
  static bool isQuestion(String text) {
    final t = text.trim();
    if (!t.endsWith('?')) return false;
    final s = _fold(t).replaceAll(RegExp(r'[?!.,]'), ' ').trim();
    if (RegExp(r'^(?:r\$\s*)?\d[\d.,]*(?:\s*(?:reais|real|conto|contos))?$').hasMatch(s)) return false;
    // "à vista?", "no pix?" — an unsure answer, not a question about the data.
    return s.split(RegExp(r'\s+')).length >= 3;
  }

  /// A hypothesis/plan ("se eu comprar…", "pretendo gastar…") or something
  /// denied ("não gastei os 66…", "quase comprei…").
  static bool isNonEvent(String text) => HypothesisDetector.notHappened(text) || HypothesisDetector.detect(text) != null;

  /// The user's own money verb in [text] (folded): first-person past
  /// ("gastei", "tomei", "vendi"), "a gente pagou", or someone doing it to
  /// the user ("o síndico me cobrou", "me devolveram", "me mandaram pagar").
  /// Value verbs ("foi", "deu", "saiu", "custou", "caiu", "entrou") are how an
  /// answer is said, not a story of its own, so they don't count.
  static RegExpMatch? ownMoneyVerb(String folded) =>
      _ownVerb.firstMatch(folded) ?? _toMeVerb.firstMatch(folded);

  static final _ownVerb = RegExp(
    r'\b(?:paguei|gastei|comprei|recebi|ganhei|vendi|torrei|quitei|transferi|mandei|depositei|abasteci|pedi|almocei|jantei|'
    r'lanchei|assinei|renovei|contratei|desembolsei|larguei|faturei|embolsei|apurei|peguei|doei|coloquei|botei|investi|'
    r'apliquei|saquei|emprestei|recarreguei|parcelei|financiei|aluguei|reservei|encomendei|rachei|apostei|pixei|cobrei|lucrei|'
    r'tomei|comi|bebi|arrumei|consertei|troquei|fiz|levei|'
    r'pagamos|gastamos|compramos|recebemos|ganhamos|vendemos|quitamos|torramos|pedimos|tomamos|comemos)\b|'
    r'\ba\s+gente\s+(?:pagou|gastou|comprou|recebeu|ganhou|vendeu|torrou|quitou|pegou|pediu|tomou|comeu)\b',
  );
  static final _toMeVerb =
      RegExp(r'\bme\s+(?:[a-z]{3,}(?:ou|aram|eu|eram|iu|iram))(?:\s+(?:pagar|pagarem|gastar|comprar|depositar|transferir))?\b');

  static final _refund = RegExp(r'\b(?:devolv|devoluc|estorn|reembols|restitu)');

  /// Where something was bought: "na petz", "no mercado do bairro", "numa
  /// banca" — up to three words after a place preposition.
  static final _placePhrase = RegExp(r'\b(?:no|na|nos|nas|num|numa|em|pelo|pela)\s+[a-z]+(?:\s+(?:d[oa]s?|de)\s+[a-z]+)?');

  /// Whether [text] tells an entry other than [subject]: its own money verb
  /// and either the money going the other way, or an object [subject] never
  /// mentioned. Same category (not "outros") = the same thing said another
  /// way ("comprei ração" ⏎ "paguei 30 na petz").
  static bool tellsAnotherStory(String text, PendingSubject subject, {String? textDirection, String? textCategory}) {
    final folded = _fold(PtNumberWords.normalize(text.toLowerCase()));
    final verb = ownMoneyVerb(folded);
    if (verb == null) return false;
    const moneyWays = {'expense', 'income'};
    if (moneyWays.contains(subject.direction) && moneyWays.contains(textDirection) && subject.direction != textDirection) return true;
    // A refund is an event of its own: "o inquilino me pagou" ⏎ "me
    // devolveram 118" is money back from something else, not the rent's
    // value — unless César is asking about a refund ("recebi o reembolso do
    // plano" ⏎ "me devolveram 118") (CHAOS-B-010).
    if (_refund.hasMatch(verb.group(0)!) && !_refund.hasMatch(_fold(subject.text))) return true;
    const vague = {null, 'unknown', 'expense_other', 'income_other'};
    final rest = folded.replaceRange(verb.start, verb.end, ' ');
    final mine = objectWords(_fold(subject.text));
    // A draft still asking where/what: "comprei ração" ⏎ "paguei 30 na petz"
    // names only *where* the same thing was bought — an answer. But a thing
    // of its own is another entry, even in the same category: "paguei a
    // lanchonete" ⏎ "tomei um café de 9", "paguei o flanelinha" ⏎ "paguei
    // 140 de pedágio" (decision of the user, 2026-10-01). A saved record
    // being edited is whole already: "gastei 30 na padaria no pix" is another
    // purchase even if the Mercado is groceries too ([PendingSubject.isRecord]).
    if (!subject.isRecord && !vague.contains(textCategory) && textCategory == subject.category) {
      final things = objectWords(rest.replaceAll(_placePhrase, ' '));
      if (things.isEmpty || mine.isEmpty) return false;
      return !things.any((w) => mine.any((p) => _sameWord(p, w)));
    }
    final theirs = objectWords(rest);
    if (theirs.isEmpty || mine.isEmpty) return false;
    return !theirs.any((w) => mine.any((p) => _sameWord(p, w)));
  }

  /// Same word, give or take a plural/diminutive/gender ending: "cerveja" ×
  /// "cervejas", "lanche" × "lanchinho".
  static bool _sameWord(String a, String b) {
    if (a == b || a.contains(b) || b.contains(a)) return true;
    final n = a.length < b.length ? a.length : b.length;
    if (n < 4) return false;
    var i = 0;
    while (i < n && a[i] == b[i]) {
      i++;
    }
    return i >= 4 && i >= n - 2;
  }

  /// The content words of [folded]: what was bought/paid/received and from
  /// whom — without verbs of value, payment, dates, numbers and function words.
  static Set<String> objectWords(String folded) => {
        for (final w in folded.split(RegExp(r'[^a-z]+')))
          if (w.length >= 3 && !_functionWords.contains(w) && !_isVerbForm(w)) w,
      };

  /// Inflected verb forms that are never the object: "-ei", "-ou", "-aram",
  /// "-eram", "-iu", and infinitives after another verb are kept only when
  /// they are common nouns too, so only the clear past forms go.
  static bool _isVerbForm(String w) => RegExp(r'^[a-z]{2,}(?:ei|ou|aram|eram|iram|amos)$').hasMatch(w);

  static String _fold(String s) => CategoryNameMatcher.foldAccents(s.toLowerCase());

  static const Set<String> _functionWords = {
    // articles, pronouns, prepositions, connectives
    'uma', 'uns', 'umas', 'dos', 'das', 'nos', 'nas', 'num', 'numa', 'pra', 'pro', 'pras', 'pros', 'para', 'pelo', 'pela',
    'com', 'sem', 'que', 'mas', 'porque', 'entao', 'tambem', 'mesmo', 'mesma', 'ate', 'sobre', 'entre', 'ele', 'ela', 'eles',
    'elas', 'voce', 'meu', 'minha', 'meus', 'minhas', 'seu', 'sua', 'seus', 'suas', 'nosso', 'nossa', 'esse', 'essa', 'este',
    'nele', 'nela', 'neles', 'nelas', 'dele', 'dela', 'deles', 'delas', 'lhe', 'nisso', 'disso', 'nesse', 'nessa', 'desse', 'dessa',
    'esta', 'isso', 'isto', 'aquele', 'aquela', 'aqui', 'ali', 'cesar', 'gente', 'tudo', 'todo', 'toda', 'todos', 'todas',
    'mais', 'menos', 'muito', 'pouco', 'bem', 'cada', 'outro', 'outra', 'ainda', 'agora', 'sim', 'nao', 'nem', 'tipo',
    // value and money words
    'reais', 'real', 'conto', 'contos', 'pila', 'pilas', 'mil', 'centavos', 'valor', 'total', 'preco', 'dinheiro',
    'foi', 'foram', 'deu', 'deram', 'saiu', 'sairam', 'custou', 'custaram', 'ficou', 'ficaram', 'era', 'eram', 'veio', 'caiu',
    'entrou', 'fechou', 'vence', 'vencem', 'cai', 'paga', 'pago', 'pagar', 'pagando', 'gastar', 'comprar', 'receber',
    // payment
    'pix', 'debito', 'credito', 'cartao', 'boleto', 'especie', 'vista', 'vezes', 'parcelado', 'parcelada', 'parcelas',
    'transferencia', 'ted', 'doc',
    // dates and times
    'hoje', 'ontem', 'anteontem', 'amanha', 'dia', 'dias', 'semana', 'mes', 'meses', 'ano', 'anos', 'passada', 'passado',
    'atras', 'segunda', 'terca', 'quarta', 'quinta', 'sexta', 'sabado', 'domingo', 'feira', 'manha', 'tarde', 'noite',
    'madrugada', 'cedo', 'hora', 'horas', 'vez',
  };
}
