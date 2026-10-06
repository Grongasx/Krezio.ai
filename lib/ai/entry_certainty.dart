import 'category_name_matcher.dart';
import 'hypothesis_detector.dart';
import 'money_direction.dart';
import 'pending_reply_check.dart';
import 'pt_number_words.dart';

/// How sure César is that what the user said is something that **already
/// happened** with money — the input of the confirmation net (Portão do lote
/// A, etapa 7e).
class CertaintyReading {
  /// High: recorded as said. Low: César shows the entry and asks "Registro
  /// assim?" before saving.
  final bool high;

  /// Why it is low (for tests and logs): 'question', 'infinitive',
  /// 'present', 'future', 'failure', 'doubt', 'no_fact'.
  final String? reason;

  const CertaintyReading.high()
      : high = true,
        reason = null;
  const CertaintyReading.low(String this.reason) : high = false;

  @override
  String toString() => high ? 'high' : 'low($reason)';
}

/// The certainty of an entry from objective signals in **every** turn the
/// user said for it (a draft completed over several turns is judged as a
/// whole: "tenho que pagar 380 de iptu" ⏎ "no boleto" is still a plan).
///
/// **Fact signals** (any one, in any turn):
/// - a money verb told in the past or as a habit, by the user or to the
///   user: "paguei", "gastei", "a gente pagou", "me cobrou 110", "o chefe me
///   pagou", "pago 85 todo mês", "foi 50", "deu 230", "anota aí…";
/// - any other first-person past verb ("consertei o carro, 300", "levei o
///   cachorro no vet, 120") — a past event told by the user — or a past
///   event told of anyone ("entrou um pix de 410", "rolou uma pizza de 58",
///   "já tinha gastado 12", "aluguel pago no pix");
/// - who pays whom said in the words ([MoneyDirectionDetector]): "a escola
///   recebeu de mim 600", "o mecânico levou 280";
/// - a verbless item — a thing and its value, nothing else ("almoço 32 no
///   pix", "uber 25", "180 do encanador"): how people jot entries down.
///
/// **Low-certainty markers** (they make it low even next to a fact):
/// - a question mark on the story ("gastei 50 no mercado?");
/// - a failure or doubt word ("deu erro", "foi recusada", "não sei se",
///   "na dúvida");
/// and, when no fact signal is present: a money verb in the infinitive
/// ("pagar 50 de luz"), in the present without a habit ("compro um tênis de
/// 300"), in the synthetic future ("pagarei"), or any conjugated verb that
/// is not a money fact ("o mercado tá caro, 300").
///
/// Plans, hypotheses and things that didn't happen are not "low": they are
/// irreal and never become a draft ([HypothesisDetector]). Pure Dart.
class EntryCertainty {
  EntryCertainty._();

  static String _fold(String s) => CategoryNameMatcher.foldAccents(PtNumberWords.normalize(s.toLowerCase()));

  /// A first-person past verb of any kind (not the synthetic future
  /// "pagarei", which ends the same way).
  static final _firstPersonPast = RegExp(r'\b(?![a-z]+(?:arei|erei|irei)\b)(?!(?:volei|joquei|hoquei|ponei|jersei)\b)[a-z]{2,}ei\b');

  /// "fui pagar a conta, 120", "fomos comprar pão": a past outing to pay.
  static final _wentToDo = RegExp(r'\b(?:fui|fomos|foi|acabei\s+de|acabamos\s+de|tive\s+que|tivemos\s+que|precisei|precisamos)\s+(?:la\s+|ali\s+|no\s+\w+\s+|na\s+\w+\s+)?[a-z]+(?:ar|er|ir)\b');

  /// A money verb in the present, said as a habit ("pago 85 todo mês").
  static final _habit = RegExp(r'\b(?:todo|toda|todos|todas)\s+(?:mes|semana|ano|dia|segunda|terca|quarta|quinta|sexta|sabado|domingo)|'
      r'\bpor\s+(?:mes|semana|ano)\b|\bao\s+mes\b|\bmensal|\bsemanal|\banual|\bsempre\b|\bvence\b|\bcai\s+(?:todo\s+)?dia\b');

  static final _presentMoneyVerb = RegExp(r'\b(?:compro|pago|gasto|recebo|vendo|invisto|transfiro|pagamos|gastamos|compramos|parcelo|financio|alugo)\b');

  static final _infinitiveMoneyVerb = RegExp(
      r'\b(?:gastar|pagar|comprar|torrar|investir|parcelar|financiar|receber|transferir|depositar|quitar|alugar|vender|contratar|assinar)\b');

  static final _futureMoneyVerb = RegExp(
      r'\b(?:gast|pag|compr|receb|torr|invest|parcel|financi|transfer|deposit|quit|alug|vend|contrat|assin)(?:arei|erei|irei|aremos|eremos|iremos|ara|era|ira)\b');

  /// "não sei se paguei", "nem lembro se já transferi", "acho que não
  /// paguei": a doubt about the money event itself. ("sei lá se foi caro,
  /// mas paguei 220", "não sei se conta, mas gastei 12" doubt something
  /// else — the fact told stands.)
  static final _doubt = RegExp(
      r'\b(?:(?:nao|nem)\s+(?:sei|lembro|tenho\s+certeza)|sei\s+la|sera\s+que)\s+(?:se\s+)?(?:(?:eu|ja|a\s+gente|nos|que)\s+)*'
      r'(?:[a-z]{3,}(?:ei|ou|amos)|foi\s+(?:pag|debitad|cobrad|descontad|transferid|depositad)\w*|caiu|entrou|passou)\b|'
      r'\bacho\s+que\s+(?:nao|nem)\b');

  /// Conjugated verb endings that are rarely nouns: past (-ou, -aram,
  /// -eram, -iram), imperfect (-ava, -avam), gerund (-ando, -endo, -indo),
  /// imperfect subjunctive (-asse, -esse, -isse), present "tá/está/estou"
  /// and the common present verbs of a comment ("tenho", "anda", "custa").
  static final _verbish = RegExp(
      r'\b(?:[a-z]{2,}(?:ou|aram|eram|iram|avam|ando|endo|indo|asse|isse)|[a-z]{3,}ava|ta|tava|esta|estava|estou|to|tem|tinha|vai|vou|ia|seria|sera|e|eh|tenho|temos|anda|andam|ando|fica|ficam|parece|parecem|custa|custam|vale|valem|acho|quero|queria|sei|gosto|precisa|precisam|cabe|compensa|rola)\b');

  /// Nouns that end like a verb ([_verbish]) but aren't one.
  static const _notVerbs = {
    'comando', 'bando', 'fernando', 'orlando', 'armando', 'interesse', 'classe', 'dividendo', 'adendo', 'lindo', 'oitava',
  };

  /// The certainty of an entry told in [turns] (in order; later turns are
  /// answers to César's questions).
  static CertaintyReading read(List<String> turns) {
    final folded = [for (final t in turns) _fold(t)];
    final story = folded.first;
    if (turns.first.trim().endsWith('?')) return const CertaintyReading.low('question');
    for (final t in turns) {
      if (HypothesisDetector.mentionsFailure(t) && !_endsOnFact(t)) return const CertaintyReading.low('failure');
    }
    for (final f in folded) {
      if (_doubt.hasMatch(f)) return const CertaintyReading.low('doubt');
    }
    final fact = _hasFact(turns, folded);
    if (fact) return const CertaintyReading.high();
    for (final f in folded) {
      if (_futureMoneyVerb.hasMatch(f)) return const CertaintyReading.low('future');
      if (_infinitiveMoneyVerb.hasMatch(f)) return const CertaintyReading.low('infinitive');
      if (_presentMoneyVerb.hasMatch(f) && !_habit.hasMatch(f)) return const CertaintyReading.low('present');
    }
    // A thing and its value, with no verb of its own: an entry jotted down.
    if (!_hasVerb(story)) return const CertaintyReading.high();
    return const CertaintyReading.low('no_fact');
  }

  static bool _hasFact(List<String> turns, List<String> folded) {
    for (var i = 0; i < turns.length; i++) {
      final t = turns[i], f = folded[i];
      if (HypothesisDetector.tellsFact(t)) return true;
      if (PendingReplyCheck.ownMoneyVerb(f) != null) return true;
      if (_firstPersonPast.hasMatch(f) || _wentToDo.hasMatch(f)) return true;
      // A past event told of anyone: "entrou um pix de 410", "caiu o vale,
      // 600", "rolou uma pizza de 58", "a loja ficou com 210 meu", "o guri
      // precisou de remédio, 42 na farmácia", "já tinha gastado 12",
      // "aluguel pago no pix", "foi pago no débito". (Plans and hypotheses
      // never get here: they are irreal before any certainty is read.)
      if (_pastTold(f)) return true;
      if (_presentMoneyVerb.hasMatch(f)) {
        // "pago 85 todo mês" is a habit told; "compro 50 no mercado" is not
        // a past fact, whatever direction it has.
        if (_habit.hasMatch(f)) return true;
        continue;
      }
      // Who pays whom said in the words. Money coming in may be said by its
      // noun ("meu salário de 4500 cai todo dia 5", "rolou um bico de 180");
      // money going out must be said by a verb or a role — a "boleto" or a
      // "do encanador" only leans a side ("pagarei 120 de luz no boleto").
      final way = MoneyDirectionDetector.detect(t);
      if (way == MoneyDirection.incoming) return true;
      if (way == MoneyDirection.outgoing && MoneyDirectionDetector.detectStrong(t) == MoneyDirection.outgoing) return true;
    }
    return false;
  }

  static final _thirdPersonPast = RegExp(r'\b[a-z]{2,}(?:ou|eu|iu|aram|eram|iram)\b');
  static final _pluperfect = RegExp(r'\b(?:tinha|tinham|tinhamos|havia|haviam)\s+(?:ja\s+)?[a-z]{3,}(?:ado|ido)\b');

  /// "pago no pix", "foi paga no débito", "aluguel pago": a money participle
  /// told as done — not "a ser pago", "vai ser paga", "precisa ser pago".
  static final _doneParticiple = RegExp(r'\b(?:pag[oa]s?|quitad[oa]s?|debitad[oa]s?|cobrad[oa]s?|transferid[oa]s?|depositad[oa]s?|'
      r'recebid[oa]s?|creditad[oa]s?|descontad[oa]s?)\b');
  static final _toBeDone = RegExp(r'\b(?:ser|sera|seria|sendo)\s+$');

  /// Words ending like a past verb that aren't one (or are present).
  static const _notPast = {'estou', 'museu', 'chapeu', 'europeu', 'trofeu', 'ilheu', 'plebeu', 'judeu', 'ateu', 'pneu', 'breu'};

  static bool _pastTold(String folded) {
    if (_pluperfect.hasMatch(folded)) return true;
    for (final m in _thirdPersonPast.allMatches(folded)) {
      if (!_notPast.contains(m.group(0)) && !_notVerbs.contains(m.group(0))) return true;
    }
    for (final m in _doneParticiple.allMatches(folded)) {
      if (!_toBeDone.hasMatch(folded.substring(0, m.start))) return true;
    }
    return false;
  }

  /// "paguei 50 mas deu erro" ends on the failure; "não era pra gastar, mas
  /// gastei 75", "ontem deu problema, paguei 380 no mecânico" end on the
  /// fact — it stands.
  static final _clauseBreak = RegExp(r'[,;:.!?]|\b(?:mas|so\s+que|porem|entretanto|e)\b');

  static bool _endsOnFact(String text) {
    final clauses = _fold(text).split(_clauseBreak).map((c) => c.trim()).where((c) => c.isNotEmpty).toList();
    return clauses.isNotEmpty && HypothesisDetector.tellsFact(clauses.last);
  }

  static bool _hasVerb(String folded) {
    for (final m in _verbish.allMatches(folded)) {
      final w = m.group(0)!;
      // "e" (and) — the copula "é" folds to it too, and "almoço é 30" is
      // still an item.
      if (w == 'e' || w == 'eh' || _notVerbs.contains(w)) continue;
      return true;
    }
    return false;
  }
}
