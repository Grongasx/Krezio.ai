import 'category_name_matcher.dart';

/// A "what if" the user is only considering ("se eu comprar um celular de
/// 2000 em 10x, quanto fica?", "e se eu gastar 300…", "caso eu pague…").
class Hypothesis {
  /// "10x", "12 parcelas", "5 vezes" — null when no installment count was said.
  final int? installments;

  /// The verb the scenario is about, as a purchase ("comprar", "gastar") —
  /// used to hand it to the affordability check.
  final bool isPurchase;

  /// Money that would come *in* ("se eu receber 800", "se meu salário fosse
  /// 5000", "se o joão me pagar 200"): not a purchase to check, but a change
  /// in the balance.
  final bool isIncome;

  /// A bill still to pay or money still to come ("tenho que pagar 380 de
  /// iptu", "falta pagar 640 do cartão"): not a simulation, a pending
  /// obligation — nothing to record until it is paid.
  final bool isObligation;

  const Hypothesis({this.installments, this.isPurchase = false, this.isIncome = false, this.isObligation = false});
}

/// Tells a hypothesis from an entry, so César never records something the
/// user only asked about (CONV-R3-003 / FEAT-R3-004), and never drops a real
/// entry that just comes with an "if" (CHAOS-A-017). The rule is grammar,
/// not a phrase list:
///
/// 1. **A fact told in the past wins.** A first-person past verb ("paguei",
///    "gastei", "recebi", "vendi"), a value that already happened ("foi 50",
///    "saiu 30") or a request to record ("anota aí…") makes the sentence an
///    entry, whatever "se/caso" clause comes with it: "…, se precisar mando o
///    comprovante", "caso você não saiba, paguei 30", "se eu gastei 45 ontem,
///    registra".
/// 2. Otherwise it is a hypothesis when it has:
///    - an explicit marker: "supondo que", "digamos que", "vamos supor",
///      "na hipótese de", "imagina se", "e se…";
///    - a conditional clause anywhere in the sentence ("…no pix se der",
///      "se o joão me pagar 200", "se o conserto sair 600"): "se"/"caso" (the
///      conjunction, not "o caso", "em caso de", nor the reflexive "ela se
///      sentir") followed by a verb in the future/imperfect subjunctive or
///      infinitive — "caso" also takes the present subjunctive ("caso eu
///      compre"). With a subject before it ("se eu", "se o joão me", "se meu
///      salário") any verb form counts; right after "se" only a recognised
///      verb does (a stem from [_stems] or an irregular form), so a title or
///      a noun after "se" is not taken for a verb;
///    - a verb in the conditional mood ("gastaria", "sobraria", "pagaria");
///    - a question about the outcome of a value ("quanto fica 2400 em 6x?",
///      "vale a pena…", "compensa…").
///
/// Idioms with "se" that only hedge ("se não me engano", "se eu lembro bem")
/// are not hypotheses. Pure Dart.
class HypothesisDetector {
  HypothesisDetector._();

  static final _hedge = RegExp(
    r'\bse\s+(?:eu\s+)?nao\s+(?:me\s+)?(?:engano|engane|falha|falhe|estou\s+enganad[oa]|to\s+enganad[oa])\b|'
    r'\bse\s+(?:eu\s+)?(?:bem\s+)?(?:me\s+)?(?:lembro|recordo)\b|\bse\s+nao\s+me\s+falha\b|\bse\s+(?:a\s+)?memoria\s+nao\b|'
    // "caso você não saiba, a academia me cobrou 110" only introduces the
    // fact (ACC-C-010).
    r'\b(?:caso|se)\s+(?:voce|vc|tu|ce)\s+(?:nao\s+)?(?:saiba|sabe|lembre|lembra|queira\s+saber|esteja\s+curios[oa])\b',
  );

  // ── 1. facts ──

  /// First-person past *money* verbs: the user telling what they paid,
  /// bought, received or sold. (Not any past verb: "achei um sofá de 2000, se
  /// eu comprar…" is still a hypothesis.)
  static final _pastMoneyVerb = RegExp(
    r'\b(?:paguei|gastei|comprei|recebi|ganhei|vendi|torrei|quitei|transferi|mandei|depositei|abasteci|pedi|almocei|jantei|'
    r'lanchei|assinei|renovei|contratei|desembolsei|larguei|faturei|embolsei|apurei|peguei|dei|doei|deixei|coloquei|botei|'
    r'investi|apliquei|saquei|emprestei|recarreguei|parcelei|financiei|aluguei|reservei|encomendei|rachei|dividi|perdi|'
    r'apostei|pixei|soltei|cobrei|lucrei|pagamos|gastamos|compramos|recebemos|ganhamos|vendemos|quitamos|torramos)\b|'
    r'\bfiz\s+(?:um|uma|o|a)\s+(?:pix|compra|pagamento|transferencia|deposito|saque)\b|'
    r'\b(?:tive|precisei)\s+(?:que|de)?\s*pagar\b|'
    r'\ba\s+gente\s+(?:pagou|gastou|comprou|recebeu|ganhou|vendeu|torrou|quitou|pegou|pediu)\b|'
    // Getting hold of an amount: "tirei 400 fazendo uber", "caiu 300 no pix".
    r'\b(?:arranjei|tirei|levantei|bati|descolei|consegui|arrumei|juntei|economizei|guardei|caiu|cairam|entrou|entraram|'
    r'pingou|pingaram|chegou|chegaram|rendeu|renderam)\s+(?:(?:uns|umas|mais|quase|r\$)\s*)?\d|'
    // "acabei de pagar 47", "tive um gasto de 58", "rolou um gasto de 37",
    // "o cliente me pagou 900" (CHAOS-B-015).
    r'\bacab(?:ei|amos)\s+de\s+[a-z]{3,}(?:ar|er|ir)\b|'
    r'\b(?:tive|tivemos|teve|rolou|houve)\s+(?:um|uma|mais\s+um|mais\s+uma)\s+(?:gasto|gastinho|despesa|compra|pagamento|entrada|receita|'
    r'conta)\b|'
    r'\bme\s+(?:pagou|pagaram|deu|deram|mandou|mandaram|transferiu|transferiram|depositou|depositaram|devolveu|devolveram|pixou|'
    r'acertou|acertaram|reembolsou|reembolsaram|cobrou|cobraram|debitou|debitaram|descontou|descontaram)\s+(?:(?:uns|umas|mais|os|r\$)\s*)?\d',
  );

  /// A value that already happened: "foi 50", "o conserto saiu 600", "deu 230".
  static final _valueTold = RegExp(
    r'\b(?:foi|foram|deu|custou|custaram|saiu|sairam|veio|vieram|ficou|ficaram)\s+(?:(?:uns|umas|so|em|por|r\$)\s*)?\d',
  );

  /// Asking to record ("anota aí se puder: 35 de lanche").
  static final _recordRequest = RegExp(
    r'^(?:(?:cesar|ei|oi|ow|por\s+favor)[, ]+)*(?:anota|anote|registra|registre|lanca|lance|coloca|coloque|bota|adiciona|'
    r'adicione|salva|salve|marca|marque)\b',
  );

  static bool _tellsFact(String s) {
    return _pastMoneyVerb.hasMatch(s) || _valueTold.hasMatch(s) || _recordRequest.hasMatch(s);
  }

  /// Whether [text] tells something that already happened with money: a
  /// first-person past money verb, a value told ("foi 50") or a request to
  /// record — the first signal of [EntryCertainty].
  static bool tellsFact(String text) =>
      _tellsFact(CategoryNameMatcher.foldAccents(text.toLowerCase()).replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll(_hedge, ' '));

  /// "deu erro", "foi recusada", "ia pagar … mas", "nem cheguei a pagar":
  /// the words of something that didn't go through, even when a money verb
  /// sits next to them ("paguei 50 mas deu erro") — a reason to confirm.
  static bool mentionsFailure(String text) =>
      _didNotHappen.hasMatch(CategoryNameMatcher.foldAccents(text.toLowerCase()).replaceAll(RegExp(r'[,;.!?]'), ' ').replaceAll(RegExp(r'\s+'), ' '));

  // ── 2. hypotheses ──

  static final _explicit = RegExp(
    r'\b(?:supondo|suponha|suponhamos|digamos|imaginando|imagine|imagina)\s+que\b|\bvamos\s+supor\b|'
    r'\b(?:na|numa)\s+hipotese\b|\bhipoteticamente\b|\b(?:imagina|imagine)\s+se\b|(?:^|[,;:.!?]\s*)e\s+se\b|'
    r'\bsimul(?:a|e|ar|acao)\b|'
    // "no caso de eu pagar…", "em caso de a gente gastar…", "na
    // eventualidade de…" (CHAOS-B-001, ACC-B-011).
    r'\b(?:no|em|num)\s+caso\s+de\s+(?:eu|a\s+gente|nos|voce|vc|ele|ela|meu|minha|o|a)\b|\bna\s+eventualidade\s+de\b|'
    // Asking whether it fits: "quero saber se dá pra…", "será que rola?".
    r'\b(?:quero|queria|gostaria\s+de|preciso)\s+saber\s+se\b|\bsera\s+que\s+(?:da|rola|cabe|consigo|posso|compensa|aguenta)\b',
  );

  /// An intention: "pretendo gastar 250", "tô pensando em comprar uma air
  /// fryer", "quero comprar uma bike de 1500", "vou gastar uns 200" — a money
  /// verb in the infinitive after a verb of wanting/planning. Not a fact, so
  /// not an entry (CHAOS-B-001). Recording verbs ("quero anotar…") are not
  /// money verbs, so they don't count.
  static final _intention = RegExp(
    r'\b(?:pretendo|pretendemos|pretendia|planejo|planejamos|planejando|planejava|pensando\s+em|penso\s+em|pensei\s+em|cogito|'
    r'cogitando|quero|queremos|queria|gostaria\s+de|vou|vamos|irei|iremos|(?:estou|to|tou|tava|estava)\s+querendo|'
    r'(?:estou|to|tou|tava)\s+a\s*fim\s+de|to\s+afim\s+de|estou\s+afim\s+de)\s+'
    r'(?:(?:te|me|ainda|so|mesmo|ja|tambem|logo|amanha|hoje|depois|uns|umas)\s+)*'
    r'(?:gastar|pagar|comprar|torrar|investir|aplicar|guardar|juntar|vender|alugar|parcelar|financiar|trocar|quitar|viajar|sacar|'
    r'depositar|transferir|mandar|emprestar|doar|dar|contratar|assinar|renovar|pedir|receber|ganhar|cobrar|pegar|tirar|levar|'
    r'desembolsar|bancar|gastar)\b',
  );

  static final _declined = RegExp(r'\b(?:nao|nem)\s+$');

  /// Money verbs in the infinitive — what a plan, an obligation or a doubt
  /// is about.
  static const _moneyInf = r'(?:gastar|pagar|comprar|torrar|investir|aplicar|guardar|juntar|depositar|transferir|mandar|emprestar|'
      r'quitar|parcelar|financiar|receber|cobrar|sacar|desembolsar|bancar|acertar|renovar|assinar|contratar|repassar|devolver|'
      r'reembolsar|doar|dar|alugar|trocar|pegar|tirar|levar|vender|ganhar|pixar|abastecer|pedir|almocar|jantar|lanchar)';

  /// An obligation still to meet: "tenho que pagar 380 de iptu", "preciso
  /// pagar 140 até sexta", "vou ter que gastar 600", "devo gastar uns 250",
  /// "falta pagar 640 do cartão", "tenho que receber 300 do joão" — nothing
  /// happened yet (CHAOS-C-001/002). ("tive que pagar" is past: a fact.)
  static final _obligation = RegExp(
    r'\b(?:tenho|temos|tem|tinha|tinhamos|teria|vou\s+ter|vamos\s+ter|vai\s+ter|preciso|precisamos|precisaria|vou\s+precisar|'
    r'devo|devemos|deveria|deveriamos|falta|faltam|faltando|faltou|ainda\s+tenho)\s+(?:que\s+|de\s+)?'
    r'(?:(?:eu|ainda|so|mesmo|tambem|logo|que)\s+)*'
    '$_moneyInf'
    r'\b',
  );

  /// A maybe, a plan, a doubt (CHAOS-C-001, ACC-C-001/016): "talvez eu
  /// gaste 215", "minha ideia é gastar 140", "pode ser que eu pague 380",
  /// "tô na dúvida se compro a air fryer", "imagina eu gastando 600".
  static final _maybe = RegExp(
    r'\btalvez\s+(?:(?:eu|a\s+gente|nos|ainda|so|ja|mesmo)\s+)*'
    r'(?:gast|pag|compr|receb|ganh|invest|torr|alug|parcel|financi|troc|quit|vend|sac|deposit|transfer|mand|emprest|ped|cobr|peg|tir|lev)'
    r'(?:e|es|emos|em|a|as|amos|am|ue|uem|ar|er|ir|asse|esse|isse)\b|'
    r'\bpode\s+ser\s+que\b|\bquem\s+sabe\s+(?:eu|a\s+gente)\b|\bcapaz\s+(?:de|que)\s+(?:eu|a\s+gente)\b|'
    r'\b(?:minha|a|nossa|meu|o)\s+(?:ideia|intencao|plano|vontade|pretensao|objetivo)\s+(?:e|eh|era|seria|ta|esta)\s+(?:de\s+)?(?:(?:eu|ainda|so)\s+)?'
    '$_moneyInf'
    r'\b|'
    r'\b(?:na|em|numa)\s+duvida\s+(?:se|entre|de|sobre)\b|\bimagin(?:a|e|ar)\s+(?:eu|a\s+gente|nos)\s+[a-z]+(?:ando|endo|indo)\b',
  );

  /// A question about spending a value ("seria loucura gastar 500 num
  /// show?", "dá pra torrar 200 nisso?"): asked, not told.
  static final _moneyInfWord = RegExp('\\b$_moneyInf\\b');

  /// It was going to happen and didn't: "ia gastar 90 no barzinho mas fiquei
  /// em casa", "era pra eu receber 300 hoje mas o cliente furou", "nem
  /// cheguei a pagar os 45", "o pix de 95 não foi, deu erro", "a compra de
  /// 640 foi recusada", "esqueci de pagar a luz" (ACC-C-002, CHAOS-C-003).
  static final _didNotHappen = RegExp(
    r'\b(?:ia|iamos|iria|iriamos|era\s+pra|era\s+para|tava\s+pra|estava\s+pra|tinha\s+que|tinha\s+de|devia|deveria|queria|pensei\s+em)\s+'
    r'(?:(?:eu|a\s+gente|nos|mim|ter\s+que|de|que|ja|hoje|ontem|amanha|ainda)\s+)*'
    '$_moneyInf'
    r'\b.*\b(?:mas|so\s+que|porem|entretanto|e\s+acabei)\b|'
    // "era pra ter caído 500 hoje mas não caiu", "ia vir 300 do cliente mas
    // não veio": what was due, then denied — whatever the verb.
    r'\b(?:ia|iamos|era\s+pra|era\s+para|devia|deveria)\s+(?:(?:eu|a\s+gente|ter)\s+)*[a-z]+(?:ar|er|ir|ado|ido)\b.*\b(?:mas|so\s+que|porem)\s+(?:nao|nem)\b|'
    r'\b(?:nao|nem)\s+(?:cheguei|chegamos|chegou|chegaram)\s+a\s+'
    '$_moneyInf'
    r'\b|'
    r'\b(?:deu|dando)\s+(?:erro|ruim|pau|problema|falha)\b|'
    r'\b(?:foi|foram|veio|ficou)\s+(?:recusad|negad|bloquead|cancelad|estornad)\w*|\b(?:recusaram|negaram|bloquearam|recusou|negou)\b|'
    r'\b(?:pix|transferencia|pagamento|compra|deposito|ted|boleto)\b(?:\s+[a-z0-9$]+){0,4}?\s+nao\s+(?:foi|passou|caiu|entrou|completou|concluiu)\b'
    r'(?!\s+(?:no|na|em|pelo|pela|via|com|de|do|da|pra|para)\b)|'
    // "o boleto de 320 voltou", "o cheque não compensou": it bounced.
    r'\b(?:pix|transferencia|pagamento|deposito|ted|boleto|cheque)\b(?:\s+[a-z0-9$]+){0,4}?\s+(?:voltou|nao\s+compensou)\b|'
    // "transferi 80 pro joão e voltou": the money came back (not "e voltou
    // 20 de troco").
    r'\b(?:transferi|pixei|mandei|depositei|paguei)\b.*\b(?:e|mas)\s+(?:o\s+(?:pix|dinheiro|pagamento|valor)\s+)?voltou\b(?!\s+(?:r\$\s*)?\d)|'
    r'\besqueci\s+de\s+'
    '$_moneyInf'
    r'\b',
  );

  /// A clause about something still to happen: "assim que cair 4500 de
  /// salário eu pago o aluguel", "quando o salário cair…" (CHAOS-B-001). A
  /// loan reminder ("ele me paga quando receber") is not a hypothesis.
  static final _whenFuture = RegExp(r'\b(?:assim\s+que|logo\s+que|depois\s+que|quando)\b');
  static final _loanOrReminder = RegExp(r'\b(?:me\s+deve|devendo|emprest\w*|me\s+paga|me\s+pagar|vai\s+me|lembr\w*|avis\w*|cobrar)\b');

  static bool _futureClause(String s) {
    if (_loanOrReminder.hasMatch(s)) return false;
    for (final clause in s.split(RegExp(r'[,;:.!?]'))) {
      final words = clause.split(RegExp(r'[^a-z0-9$]+')).where((w) => w.isNotEmpty).toList();
      for (var i = 0; i < words.length; i++) {
        final two = i + 1 < words.length ? '${words[i]} ${words[i + 1]}' : '';
        int? at;
        if (words[i] == 'quando') {
          at = i + 1;
        } else if (const {'assim que', 'logo que', 'depois que'}.contains(two)) {
          at = i + 2;
        }
        if (at != null && _conditionalVerbAfter(words, at, presentToo: false)) return true;
      }
    }
    return false;
  }

  /// Stems of the verbs people put in a money hypothesis. Right after "se"
  /// (no subject), only these — or an irregular form — count as a verb.
  static const _stems = r'(?:gast|pag|compr|receb|ganh|invest|junt|guard|economiz|sobr|rest|falt|fic|cust|vend|alug|parcel|'
      r'financi|troc|quit|viaj|sac|deposit|transfer|cobr|aument|diminu|cort|entr|rend|tir|peg|precis|atras|quebr|ped|melhor|'
      r'pass|consegu|abr|fech|contrat|assin|renov|mand|emprest|dev|acontec|cheg|demor|aprov|perd|conserv|reform|mud|'
      r'caber|faz|rol|torr|pint|trabalh|sub|baix|dobr|aplic|lucr|fatur|embols|cancel|pedi|chov|esquec|us|dar|ter|ser)';

  /// Future/imperfect subjunctive or infinitive endings.
  static const _subjEndings = r'(?:ar|er|ir|armos|ermos|irmos|arem|erem|irem|asse|esse|isse|assem|essem|issem|assemos|essemos|issemos)';

  /// Present subjunctive endings ("caso eu compre", "caso a gente receba").
  static const _presSubjEndings = r'(?:e|es|emos|em|a|as|amos|am|ue|uem|que|quem)';

  static const _irregular = {
    'for', 'formos', 'forem', 'fosse', 'fossemos', 'fossem', 'der', 'dermos', 'derem', 'desse', 'dessemos', 'dessem',
    'tiver', 'tivermos', 'tiverem', 'tivesse', 'tivessem', 'puder', 'pudermos', 'puderem', 'pudesse', 'pudessem',
    'quiser', 'quiserem', 'quisesse', 'quisessem', 'fizer', 'fizermos', 'fizerem', 'fizesse', 'fizessem', 'vier', 'vierem',
    'viesse', 'viessem', 'estiver', 'estiverem', 'estivesse', 'estivessem', 'houver', 'houvesse', 'souber', 'soubesse',
    'couber', 'coubesse', 'trouxer', 'trouxesse', 'disser', 'dissesse', 'puser', 'pusesse', 'sair', 'sairem', 'saisse',
    'cair', 'cairem', 'caisse', 'ir', 'vir', 'conseguir', 'conseguisse',
  };

  /// Irregular present subjunctive, after "caso" ("caso esteja", "caso eu faça").
  static const _irregularPresent = {
    'seja', 'sejam', 'esteja', 'estejam', 'saiba', 'saibam', 'queira', 'queiram', 'possa', 'possam', 'tenha', 'tenham',
    'faca', 'facam', 'va', 'vamos', 'de', 'haja', 'caiba', 'traga', 'diga', 'ponha', 'venha', 'consiga', 'consigam', 'saia',
    'caia', 'pague', 'paguem', 'fique', 'fiquem', 'aplique', 'chegue', 'invista', 'perca',
  };

  static final _anyVerbForm = RegExp('^[a-z]{2,}$_subjEndings\$');
  static final _stemVerbForm = RegExp('^$_stems$_subjEndings\$');
  static final _stemPresentSubj = RegExp('^$_stems$_presSubjEndings\$');

  static const _subjectPronouns = {'eu', 'nos', 'voce', 'vc', 'ele', 'ela', 'eles', 'elas', 'tu', 'voces'};
  static const _determiners = {'o', 'a', 'os', 'as', 'meu', 'minha', 'meus', 'minhas', 'seu', 'sua', 'nosso', 'nossa', 'esse', 'essa'};
  static const _clitics = {'me', 'te', 'nos', 'lhe', 'se', 'nao', 'ja', 'so', 'mesmo', 'tambem', 'realmente'};
  static const _adverbs = {
    'amanha', 'hoje', 'depois', 'agora', 'ainda', 'ja', 'so', 'mesmo', 'realmente', 'tambem', 'nao', 'algum', 'dia', 'um',
    'mes', 'que', 'vem', 'semana', 'por', 'acaso', 'de', 'repente', 'no', 'fim', 'do',
  };

  /// Words right before "se" that make it the reflexive pronoun ("pra ela se
  /// sentir segura", "você se aposentar") or an indirect question ("vê se").
  static const _reflexiveBefore = {'ele', 'ela', 'eles', 'elas', 'voce', 'vc', 'gente', 'eu', 'pra', 'para', 'pro', 'nos', 'tu', 've', 'veja', 'confere', 'confira', 'sei', 'saber'};

  /// Words before "caso" that make it a noun ("o caso", "do caso trabalhista",
  /// "em caso de emergência", "esse caso tá caro").
  static const _nounCaseBefore = {
    'o', 'do', 'no', 'num', 'em', 'pelo', 'esse', 'este', 'nesse', 'neste', 'desse', 'deste', 'um', 'qualquer', 'cada',
    'seu', 'meu', 'ao', 'de', 'outro', 'mesmo', 'aquele', 'naquele', 'daquele', 'tal', 'certo', 'grande', 'nosso',
  };

  /// Whether the clause starting after "se"/"caso" (in [words], from [i]) has
  /// a conditional verb: optional adverbs, an optional subject, optional
  /// clitics, then the verb.
  static bool _conditionalVerbAfter(List<String> words, int i, {required bool presentToo}) {
    var j = i;
    while (j < words.length && _adverbs.contains(words[j]) && j - i < 4) {
      j++;
    }
    var subject = false;
    if (j < words.length && _subjectPronouns.contains(words[j])) {
      subject = true;
      j++;
    } else if (j + 1 < words.length && words[j] == 'a' && words[j + 1] == 'gente') {
      subject = true;
      j += 2;
    } else if (j + 1 < words.length && _determiners.contains(words[j])) {
      // "se o joão", "se meu salário", "se o conserto do carro", "caso a
      // minha mãe" (ACC-B-011)
      subject = true;
      while (j + 1 < words.length && _determiners.contains(words[j])) {
        j++;
      }
      j++;
      if (j + 1 < words.length && RegExp(r'^d[oa]s?$|^de$').hasMatch(words[j])) j += 2;
    }
    while (j < words.length && _clitics.contains(words[j])) {
      j++;
    }
    while (j < words.length && _adverbs.contains(words[j]) && !_irregular.contains(words[j])) {
      j++;
    }
    if (j >= words.length) return false;
    final w = words[j];
    if (_irregular.contains(w) || _stemVerbForm.hasMatch(w)) return true;
    if (presentToo && (_irregularPresent.contains(w) || _stemPresentSubj.hasMatch(w))) return true;
    return subject && _anyVerbForm.hasMatch(w);
  }

  static bool _conditionalClause(String s) {
    // Clause by clause, so a verb in the next clause isn't taken for this one.
    for (final clause in s.split(RegExp(r'[,;:.!?]'))) {
      final words = clause.split(RegExp(r'[^a-z0-9$]+')).where((w) => w.isNotEmpty).toList();
      for (var i = 0; i < words.length; i++) {
        final w = words[i];
        if (w != 'se' && w != 'caso') continue;
        final before = i > 0 ? words[i - 1] : '';
        if (w == 'se') {
          if (_reflexiveBefore.contains(before)) continue;
          if (_conditionalVerbAfter(words, i + 1, presentToo: false)) return true;
        } else {
          if (_nounCaseBefore.contains(before)) continue;
          if (i + 1 < words.length && const {'de', 'do', 'da', 'que', 'e', 'foi', 'era', 'ta', 'esta'}.contains(words[i + 1])) continue;
          if (_conditionalVerbAfter(words, i + 1, presentToo: true)) return true;
        }
      }
    }
    return false;
  }

  /// Conditional mood of a money verb: "gastaria", "sobraria", "pagaria",
  /// "daria", "teria". (Stems, so "padaria"/"pizzaria" are not verbs.)
  static final _conditionalMood = RegExp(
    r'\b(?:gast|pag|compr|sobr|rest|falt|fic|cust|receb|ganh|invest|junt|guard|economiz|alug|parcel|financi|troc|quit|viaj|'
    r'vend|sa|d|t|pod|consegu|cab|rend|f)(?:aria|eria|iria|ariamos|eriamos|iriamos|ariam|eriam|iriam)\b',
  );

  static final _outcomeQuestion = RegExp(
    r'\bquanto\s+(?:fica|ficaria|ficam|ficariam|sai|sairia|saem|daria|seria|sobra|sobraria|resta|restaria|fico|teria|pesa|pesaria|'
    r'vai\s+(?:ficar|sair|dar|ser|sobrar|pesar))\b|\bpesa(?:ria)?\s+quanto\b|\bvale(?:ria)?\s+a\s+pena\b|\bcompensa(?:ria)?\b',
  );

  static final _installments = RegExp(r'\b(\d{1,2})\s*(?:x\b|vezes\b|parcelas?\b|prestac\w*)');
  static final _purchaseVerb = RegExp(r'\b(?:compr|parcel|gast|pag|fiz|faz|fac|tir)\w*');

  /// Money coming in: receiving/earning verbs in any form, someone paying
  /// *me*, or an income as the subject ("se meu salário fosse 5000").
  static final _incomeVerb = RegExp(
    r'\b(?:receb|ganh|fatur|lucr|embols|vend)\w*|\bme\s+(?:pag|dess|der|de\b|dar|devolv|mand|transfer|deposit|pix)\w*|'
    r'\b(?:salario|renda|freela|bonus|comissao|13o|decimo\s+terceiro|aumento|reembolso|restituicao|heranca|premio)\b',
  );

  /// The hypothesis in [text], or null when it tells or asks something else.
  /// First-person past money verbs, alone (no value needed after them).
  static final _moneyVerbWord = RegExp(
    r'\b(?:paguei|gastei|comprei|recebi|ganhei|vendi|torrei|quitei|transferi|mandei|depositei|abasteci|pedi|almocei|jantei|'
    r'lanchei|assinei|renovei|contratei|desembolsei|larguei|faturei|embolsei|peguei|dei|doei|coloquei|botei|investi|apliquei|'
    r'saquei|emprestei|recarreguei|parcelei|financiei|aluguei|reservei|encomendei|rachei|apostei|pixei|cobrei|tomei|comi|bebi|'
    r'pagamos|gastamos|compramos|recebemos|ganhamos|vendemos|torramos)\b',
  );

  /// What comes right before a verb that did not happen: "não gastei",
  /// "nem paguei", "quase comprei", "por pouco não torrei", "acabei não
  /// pagando" is not a past form, so only the forms with the past verb.
  static final _missBefore = RegExp(
    r'(?:\b(?:nao|nem|nunca|jamais|quase)|\bpor\s+pouco(?:\s+(?:que\s+)?nao)?|\bacabei\s+(?:nao|nem))\s+'
    r'(?:(?:eu|te|me|lhe|o|a|ainda|ja|mais|mesmo|cheguei\s+a|tinha|tenho)\s+)*$',
  );

  /// "não gastei muito, uns 30", "nem paguei tanto": a degree, not a denial.
  static final _degreeAfter = RegExp(r'^\s+(?:muito|tanto|tudo|so|somente|apenas|mais\s+(?:que|de|do\s+que)|menos\s+(?:que|de))\b');

  /// Giving up before it happened: "desisti de comprar o tênis", "deixei de
  /// pagar a academia esse mês".
  static final _gaveUp = RegExp(r'\b(?:desisti|desistimos|desisto)\s+d[aoe]s?\b|\bdeixei\s+de\s+(?:pagar|comprar|gastar|assinar|renovar)\b');

  /// Something the user says did **not** happen — every money verb in the
  /// sentence is denied ("não gastei os 66 que tinha separado pro bar", "por
  /// pouco não torrei 118 no cassino", "quase comprei um tênis de 300"), or
  /// the user gave up on it. Nothing to record, and nothing to ask about
  /// (the 7c left these as drafts asking for the payment). One money verb
  /// that is *not* denied, or a value told ("foi 50"), makes it a fact:
  /// "não paguei no crédito, paguei 50 no pix".
  static bool notHappened(String text) {
    final s = CategoryNameMatcher.foldAccents(text.toLowerCase()).replaceAll(RegExp(r'[,;.!?]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (_valueTold.hasMatch(s)) return false;
    final verbs = _moneyVerbWord.allMatches(s).toList();
    if (verbs.isEmpty) {
      if (_didNotHappen.hasMatch(s)) return true;
      return _gaveUp.hasMatch(s) && !RegExp(r'\d').hasMatch(s.substring(0, _gaveUp.firstMatch(s)!.start));
    }
    for (final v in verbs) {
      final denied = _missBefore.hasMatch(s.substring(0, v.start)) && !_degreeAfter.hasMatch(s.substring(v.end));
      if (!denied) return false;
    }
    return true;
  }

  static Hypothesis? detect(String text) {
    final s = CategoryNameMatcher.foldAccents(text.toLowerCase()).replaceAll(RegExp(r'\s+'), ' ').trim();
    final w = s.replaceAll(_hedge, ' ');
    if (_tellsFact(w)) return null;
    final hasDigit = RegExp(r'\d').hasMatch(w);
    final obligation = _obligation.hasMatch(w);
    final hypothesis = obligation ||
        _maybe.hasMatch(w) ||
        // "seria loucura gastar 500 num show?": a question about spending a
        // value is asked, not told.
        (w.endsWith('?') && hasDigit && _moneyInfWord.hasMatch(w)) ||
        _explicit.hasMatch(w) ||
        // Declining with no value ("não quero parcelar", "nem vou pedir")
        // answers a question; it is no plan. With a value ("não vou gastar
        // 300 no mercado") it is still nothing that happened.
        (_intention.hasMatch(w) && (hasDigit || _intention.allMatches(w).any((m) => !_declined.hasMatch(w.substring(0, m.start))))) ||
        _futureClause(w) ||
        _conditionalClause(w) ||
        _conditionalMood.hasMatch(w) ||
        (_outcomeQuestion.hasMatch(w) && hasDigit);
    if (!hypothesis) return null;
    final inst = _installments.firstMatch(w);
    final n = inst == null ? null : int.tryParse(inst.group(1)!);
    // "se o cliente me pagar 900": paying *me* is not the user buying.
    final purchase = _purchaseVerb.hasMatch(w.replaceAll(RegExp(r'\bme\s+pag\w*'), ' '));
    return Hypothesis(
      installments: (n != null && n >= 2) ? n : null,
      isPurchase: purchase,
      isIncome: !purchase && _incomeVerb.hasMatch(w),
      isObligation: obligation,
    );
  }
}
