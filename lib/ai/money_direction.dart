import 'category_name_matcher.dart';

/// Which way the money went, as the sentence says it.
enum MoneyDirection {
  /// Left the user's pocket: a payment, purchase, fee, charge.
  outgoing,

  /// Came to the user: someone paid/gave/deposited, the user earned it.
  incoming,

  /// The sentence says both ("paguei… e me deram…") — ask, don't guess.
  conflict,

  /// The amount hangs on a verb César doesn't know the direction of
  /// ("arranjei 150", "levantei 500", "o vendedor me empurrou um seguro de
  /// 90") — ask "entrou ou saiu?", don't let the classifier guess.
  unclear,

  /// Nothing in the wording decides it; the classifier's guess stands.
  unknown,
}

/// Decides income × expense from *who pays whom* in the sentence, instead of
/// from which verbs the classifier happened to see in training (R2-CONV-002,
/// 003, 017; ACC-A-001/002/011; CHAOS-A-004/005). The rule is by role, not
/// per phrase:
///
/// - **The user pays** (outgoing): a first-person paying verb ("paguei",
///   "gastei", "quitei", "comprei"), "efetuei/fiz o pagamento", "saiu (N) da
///   minha conta", "me cobraram", "debitaram", an explicit "registre uma
///   despesa"; someone making the user pay ("me mandou/obrigou/fez **pagar**",
///   "me convenceu a **gastar**"); a *charge* reaching the user, whatever the
///   verb ("caiu o débito automático", "ganhei uma multa", "me passou a
///   conta", "me mandaram um boleto"); a bill's due day ("o spotify cai dia
///   3"); weaker: the *thing paid* ("taxa", "matrícula", "multa", "boleto").
/// - **The user receives** (incoming): a first-person receiving or selling
///   verb ("recebi", "ganhei", "faturei", "vendi", "apurei", "passei … pra
///   frente"), someone handing *money* to me ("me deu 50", "me mandou um pix
///   de 100", "me descolou 200" — the object must be money: "me empurrou um
///   seguro de 90" is not), a third person paying *an amount* ("o chefe pagou
///   180"), an explicit "registre uma receita"; weaker: what one earns
///   ("honorários", "salário", "um extra", "um bico").
/// - **Nobody said** (unclear): the amount hangs on a first-person verb that is
///   neither ("arranjei 150", "levantei 500", "bati 300"). What was done to
///   earn it ("fazendo faxina", "vendendo roupa", "de gorjeta") settles it as
///   income; otherwise César asks. The classifier was confidently wrong on
///   exactly these (0.93–0.98 "despesa").
///
/// Strong signals beat weak ones. Strong signals both ways ("paguei 50 e me
/// devolveram 20" in one entry) are a [MoneyDirection.conflict]. Pure Dart.
class MoneyDirectionDetector {
  MoneyDirectionDetector._();

  /// What a bill/charge is called. A charge is never income, whatever verb
  /// brings it ("caiu", "chegou", "ganhei", "me mandou").
  static const _charge = r'(?:conta|contas|boleto|boletos|cobranca|cobrancas|fatura|faturas|multa|multas|notificacao|carne|'
      r'debito\s+automatico|taxa|taxas|tarifa|tarifas|anuidade|juros|iof|mensalidade|parcela|parcelas|prestacao|assinatura|'
      r'encargos?|orcamento|guia|imposto|ipva|iptu)';
  static const _det = r'(?:(?:a|o|as|os|uma|um|essa|esse|minha|meu|mais|outra|outro|aquela|aquele|nova|novo|baita|bela)\s+)*';

  // "recebi a conta de luz", "caiu o débito automático de 89", "ganhei uma
  // multa de 195": a bill arriving, not money.
  static final _chargeArrives = RegExp(
    r'\b(?:chegou|chegaram|veio|vieram|caiu|cairam|cai|caem|ganhei|ganhamos|levei|levamos|tomei|tomamos|'
    r'entrou|entraram)\s+' '$_det$_charge' r'\b|'
    // "recebi a parcela do acordo" can be money: only a bill proper here.
    r'\b(?:recebi|recebemos)\s+' '$_det' r'(?:conta|boleto|cobranca|fatura|multa|notificacao|carne|orcamento)\b',
  );

  // "me passou a conta de 80", "me mandaram um boleto", "me passaram um
  // orçamento de 400". Paying/returning verbs keep their meaning ("me
  // devolveu a taxa" is a refund; "me pagou a conta" is handled below).
  static final _chargeHandedToMe = RegExp(r'\bme\s+([a-z]+)\s+' '$_det$_charge' r'\b');
  static final _payingVerb = RegExp(r'^(?:pag|quit|acert|reembols|devolv|transfer|deposit|pix|restitu|estorn|cobr|debit|descont)');

  // "me mandou pagar 50 de luz", "me obrigaram a pagar", "me fizeram pagar",
  // "me convenceu a gastar 200": the user is the one who pays.
  static final _madeToPay = RegExp(
    r'\bme\s+[a-z]+\s+(?:a\s+|pra\s+|para\s+|de\s+)?(?:pagar|gastar|comprar|quitar|desembolsar|bancar|arcar|contratar|assinar|'
    r'torrar|investir|depositar|transferir|pixar|mandar|emprestar|dar)\b',
  );

  // "o spotify cai dia 3", "a academia vence todo dia 10": a due day is a
  // bill's; only an income named as the subject ("meu salário cai dia 5")
  // makes it money coming in.
  static final _dueDay = RegExp(
    r'\b(?:cai|caem|vence|vencem|debita|debitam|renova|renovam|e\s+cobrad[oa]|sao\s+cobrad[oa]s)\s+(?:(?:todo|sempre|no|na|todos\s+os)\s+)*dias?\s+\d',
  );
  static final _incomeNoun = RegExp(
    r'\b(?:salario|salarios|pagamento|pro-?labore|holerite|renda|aposentadoria|pensao|beneficio|bolsa|comissao|rendimentos?|'
    r'dividendos?|proventos?|freela|mesada|vale|adiantamento|quinzena|13o|decimo)\b',
  );

  /// People paid for a service (vocabulary): money handed to them, or a value
  /// "do encanador", is the user paying (ACC-C-004/007).
  static const provider = r'(?:pedreir[oa]s?|encanador(?:a|es)?|eletricistas?|mecanic[oa]s?|diaristas?|faxineir[oa]s?|pintor(?:a|es)?|'
      r'jardineir[oa]s?|marceneir[oa]s?|serralheir[oa]s?|vidraceir[oa]s?|chaveir[oa]s?|borracheir[oa]s?|motoboys?|entregador(?:a|es)?|'
      r'flanelinhas?|manicures?|cabeleireir[oa]s?|barbeir[oa]s?|dentistas?|medic[oa]s?|advogad[oa]s?|contador(?:a|es)?|personal|'
      r'baba|costureir[oa]s?|sapateir[oa]s?|tecnico|tecnica|montador(?:a|es)?|frete(?:iro)?|carreto|guincho|dedetizador|'
      r'veterinari[oa]|psicolog[oa]|fisioterapeuta|nutricionista|professor(?:a)?\s+particular|piscineiro|gesseir[oa]|azulejista|'
      r'servente|ajudante|caseir[oa]|cuidador(?:a)?|motorista|taxista|despachante|lavador)';

  static final _strongOut = [
    RegExp(r'\b(?:paguei|pagamos|gastei|gastamos|comprei|compramos|quitei|quitamos|torrei|larguei|desembolsei|'
        r'contratei|assinei|renovei|abasteci|tive\s+que\s+pagar|precisei\s+pagar)\b'),
    // Money handed to someone paid for a service: "dei um dinheiro pro
    // pedreiro", "passei 200 pro eletricista" (ACC-C-004).
    RegExp(r'\b(?:dei|demos|passei|mandei|repassei|adiantei|pixei|transferi|acertei|entreguei)\b(?:\s+[a-z0-9$.,]+){0,6}?\s+'
        r'(?:pr[oa]s?|para|ao|a)\s+(?:(?:o|a|os|as|meu|minha|seu|sua|dona|seu)\s+)?' '$provider' r'\b'),
    RegExp(r'\ba\s+gente\s+(?:pagou|gastou|comprou|torrou|quitou)\b'),
    // Giving a value away: "deixei 26 de gorjeta pro garçom", "doei 50 pra
    // creche" — out of the user's pocket, whoever got it (the classifier
    // calls it a transfer, and "entrou ou saiu?" was asked).
    RegExp(r'\b(?:doei|doamos|deixei|deixamos)\s+(?:(?:uns|umas|mais|r\$)\s*)?\d'),
    RegExp(r'\bacab(?:ei|amos)\s+de\s+(?:pagar|gastar|comprar|torrar|quitar|desembolsar|abastecer|pedir|transferir|mandar)\b'),
    RegExp(r'\b(?:efetuei|efetuamos|realizei|realizamos|fiz|fizemos)\s+(?:o\s+|um\s+|uma\s+|a\s+)?(?:pagamento|quitacao|compra)\b'),
    RegExp(r'\bsai(?:u|ram)\s+(?:(?:r\$\s*)?\d[\d.,]*\s*(?:reais\s+)?)?d[ae]\s+(?:minha\s+|nossa\s+)?conta\b'),
    // The habitual present with its value: "todo mês pago 150 da escolinha"
    // (ACC-B-002), "gasto uns 300 por mês de mercado".
    RegExp(r'\b(?:pago|pagamos|gasto|gastamos|compro|compramos|desembolso)\s+(?:(?:uns|umas|mais|r\$)\s*)?\d'),
    // Someone taking the money: "o mecânico levou 280", "descontaram 55 do
    // meu salário", "o posto cobrou 210" (ACC-B-012).
    RegExp(r'(?:^|[,;:]\s*|\b(?!eu\b|gente\b|nos\b|que\b|me\b|te\b|se\b)[a-z]+\s+)(?:levou|levaram|cobrou|cobraram|descontou|descontaram|'
        r'debitou|debitaram|tomou|tomaram|abocanhou|comeu|morderam|mordeu)\s+(?:(?:uns|umas|mais|r\$)\s*)?\d'),
    RegExp(r'\bme\s+(?:cobrou|cobraram|debitou|debitaram|descontou|descontaram)\b|\bdebitaram\b|\bfui\s+cobrad[oa]\b'),
    // The user as the one who paid, said by role (ACC-C-015): "o motoboy
    // recebeu 15 de mim", "a escola recebeu de mim 600", "quem bancou o
    // jantar fui eu", "fui eu que paguei".
    RegExp(r'\b(?:recebeu|receberam|levou|levaram|ganhou|ganharam|cobrou|cobraram|tirou|tiraram)\b(?:\s+[a-z0-9$.,]+){0,4}?\s+de\s+mim\b|'
        r'\bquem\s+(?:pagou|bancou|acertou|gastou|desembolsou|arcou)\b.*\bfui\s+eu\b|\bfui\s+eu\s+(?:que|quem)\s+(?:paguei|pagou|banquei|bancou|acertei|acertou|gastei)\b'),
    RegExp(r'\b(?:registr|lanc|anot|adicion|coloc|inclu)\w*\s+(?:de\s+)?(?:uma?\s+)?(?:despesa|gasto|saida|pagamento\s+feito)\b'),
  ];

  static final _weakOut = [
    // "180 do encanador", "o pedreiro, 1500": the provider's value (ACC-C-007).
    RegExp(r'\b(?:d[oa]s?|pr[oa]s?|com\s+(?:o|a)|n[oa])\s+' '$provider' r'\b'),
    RegExp(r'\b(?:pagamento|quitacao)\s+(?:d[oa]s?|de|referente)\b'),
    RegExp(r'\b(?:taxa|taxas|matricula|mensalidade|multa|boleto|fatura|parcela|prestacao|iptu|ipva|licenciamento|tarifa)\b'),
  ];

  static final _strongIn = [
    // Receiving, earning, selling ("vendi a bike por 300", "apurei 130").
    RegExp(r'\b(?:recebi|recebemos|ganhei|ganhamos|faturei|faturamos|embolsei|lucrei|lucramos|vendi|vendemos|apurei|apuramos|'
        r'cobrei|cobramos|herdei|herdamos)\b|\bacab(?:ei|amos)\s+de\s+(?:receber|ganhar|vender|faturar)\b'),
    // Compensation and borrowed money coming in: "a seguradora indenizou
    // 3800", "peguei 500 emprestado com a minha mãe" (ACC-C-004, CHAOS-C-009).
    RegExp(r'\b(?:indenizou|indenizaram|ressarciu|ressarciram|fui\s+indenizad[oa]|fui\s+ressarcid[oa])\b|'
        r'\b(?:peguei|pegamos|tomei|tomamos|consegui|conseguimos|pedi|pedimos)\s+(?:(?:uns|umas|mais|r\$)\s*)?\d[\d.,]*\s*(?:reais|real|conto|contos|pila)?\s*emprestad[oa]s?\b|'
        r'\b(?:peguei|pegamos|tomei|tomamos|consegui|pedi|pedimos)\s+emprestad[oa]s?\s+(?:(?:uns|umas|r\$)\s*)?\d'),
    // A sale told with the noun: "fiz uma venda de 58", "fechei uma venda"
    // (CHAOS-B-006).
    RegExp(r'\b(?:fiz|fizemos|fechei|fechamos|realizei|realizamos|tive|tivemos)\s+(?:uma|a|mais\s+uma|outra)\s+vendas?\b'),
    // Income arriving by name: "caiu a restituição do imposto 1340", "entrou
    // o reembolso", "saiu meu salário" (ACC-B-001).
    RegExp(r'\b(?:caiu|cairam|cai|caem|entrou|entraram|chegou|chegaram|veio|vieram|pingou|saiu|sairam)\s+' '$_det'
        r'(?:restituicao|reembolso|estorno|cashback|salario|pagamento\s+d[oa]\s+(?:cliente|freela|servico)|pensao|aposentadoria|'
        r'beneficio|comissao|bonus|plr|rescisao|indenizacao|premio|heranca|rendimentos?|dividendos?|proventos?|mesada|auxilio)\b'),
    // A transfer named by who it came from, with no verb: "pix de 90 da
    // carla", "transferência de 200 do joão" (ACC-B-001).
    RegExp(r'^(?:(?:um|uma|o|a)\s+)?(?:pix|pixzinho|transferencia|ted|doc|deposito)\s+(?:de\s+)?(?:r\$\s*)?\d[\d.,]*\s*(?:reais\s+|conto\s+|contos\s+)?d[oa]s?\s+[a-z]'),
    // Selling in other words: "passei meu celular velho pra frente por 700".
    RegExp(r'\bpass(?:ei|amos)\s+(?:[a-z]+\s+){0,4}?(?:pra|para)\s+frente\b'),
    // Someone paying/giving *to me* — the verbs that only ever mean that.
    RegExp(r'\bme\s+(?:deu|deram|pagou|pagaram|transferiu|transferiram|depositou|depositaram|devolveu|devolveram|'
        r'reembolsou|reembolsaram|presenteou|acertou|acertaram|pixou)\b'),
    // "meu cunhado acertou comigo os 180" (ACC-C-015).
    RegExp(r'\b(?:acertou|acertaram|pagou|pagaram|quitou|quitaram|devolveu|devolveram)\s+comigo\b'),
    RegExp(r'\b(?:registr|lanc|anot|adicion|coloc|inclu)\w*\s+(?:de\s+)?(?:uma?\s+)?(?:receita|entrada|recebimento)\b'),
  ];

  /// Someone handing money *to me* with any verb ("me descolou 200", "me
  /// arrumou 150", "me adiantou 500", "me mandou um pix de 100") — the "me"
  /// makes the user the receiver (CONV-R3-001) **when what is handed over is
  /// money**: the amount itself or a money noun right after the verb. "me
  /// mandou pagar 50", "me passou a conta de 80", "me empurrou um seguro de
  /// 90" hand over something else (CHAOS-A-004). Verbs where "me" is the one
  /// charged/sold to or asked ("me cobrou", "me vendeu") never are.
  static final _toMeVerb = RegExp(r'\bme\s+([a-z]+(?:ou|eu|iu|aram|eram|iram))\b');
  static final _givingVerb = RegExp(
    r'^(?:d(?:eu|eram)|pag|mand|pass|envi|transfer|deposit|devolv|reembols|pix|adiant|emprest|descol|arrum|arranj|present|'
    r'acert|do(?:ou|aram)|repass|liber|jog|ping|restitu|estorn|banc)',
  );
  static final _chargedToMe = RegExp(r'^(?:cobr|debit|descont|vend|cust|alug|roub|lev|tir|mult|fatur|engan|ped|exig|solicit)');
  static final _moneyObject = RegExp(
    r'^(?:\s+(?:de\s+volta|mais|uns|umas|quase|tipo|os|as|o|a|um|uma|so|la|ai|agora|hoje|ontem|a\s+quantia\s+de|o\s+valor\s+de))*'
    r'(?:\s*(?:r\$\s*)?\d|'
    // "me mandou um pix de 100", "me passou o dinheiro do aluguel, 1200"
    r'\s+(?:pix|pixzinho|transferencia|ted|doc|deposito|dinheiro|grana|graninha|trocado|adiantamento|ajuda|reais|conto|contos)\b'
    r'(?:[\s,]+[a-z]+){0,4}?[\s,]*(?:r\$\s*)?\d)',
  );
  // "me empurrou um seguro de 90": something other than money handed to me,
  // with a price. Not income — but not clearly a purchase either: ask.
  static final _thingWithPrice = RegExp(r'^\s+' '$_det' r'[a-z]+(?:\s+[a-z]+)?\s+(?:de|por)\s+(?:r\$\s*)?\d');

  /// The money itself arriving: "caiu 300", "pingou 90", "entraram 350",
  /// "chegou 1200", "rendeu 40" — the amount is the subject, right after the
  /// verb (a bill arriving names the bill first: "caiu a fatura de 900").
  static final _moneyArrives = RegExp(
    r'\b(?:caiu|cairam|pingou|pingaram|entrou|entraram|chegou|chegaram|brotou|brotaram|rendeu|renderam)\s+'
    r'(?:(?:mais|uns|umas|quase|tipo)\s+)?(?:r\$\s*)?\d',
  );
  // "caiu 300 da minha conta" left it; "entrou 500 na fatura do cartão" is a
  // charge landing on the bill — neither is money for the user.
  static final _leftMyAccount =
      RegExp(r'\b(?:d[ao]s?)\s+(?:minha|meu)\s+(?:conta|saldo|cartao|limite)\b|\bfatura|\bcartao|\bcobranca|\bboleto');

  /// The user getting hold of money: "fiz uma graninha", "fiz um extra",
  /// "descolei 250", "arrumei uma grana".
  static final _userEarned = RegExp(
    r'\b(?:fiz|fizemos|faco|descolei|descolamos|arrumei|consegui|levantei|tirei|arranjei|bati)\s+(?:um\s+|uma\s+|uns\s+|umas\s+)?'
    r'(?:grana|graninha|granas|dinheiro|dinheirinho|trocado|trocadinho|extra|extrinha|renda|bico|bicos|bufunfa|dindin|lucro)\b|'
    r'\b(?:descolei|descolamos|embolsei)\s+(?:(?:uns|umas|mais)\s+)?(?:r\$\s*)?\d',
  );

  /// "me <verb> …" read by who ends up with the amount: money handed over
  /// with a giving verb → incoming; an amount taken or charged ("me cobrou
  /// 50", "me levaram 80") → outgoing; money with any other verb ("me
  /// assaltaram 200") or a thing with a price ("me empurrou um seguro de 90")
  /// → unclear; nothing said → null.
  static MoneyDirection? _handedToMe(String s) {
    MoneyDirection? found;
    for (final m in _toMeVerb.allMatches(s)) {
      final verb = m.group(1)!;
      final after = s.substring(m.end);
      if (_chargedToMe.hasMatch(verb)) {
        // "me cobrou 50", "me levaram 80", "me vendeu um fone de 120": the
        // amount left me.
        // ("me pediu 50" only asked.)
        if (!RegExp(r'^(?:ped|exig|solicit)').hasMatch(verb) && (_moneyObject.hasMatch(after) || _thingWithPrice.hasMatch(after))) {
          return MoneyDirection.outgoing;
        }
        continue;
      }
      if (_moneyObject.hasMatch(after)) {
        // Money with a verb of handing over is mine; with any other verb
        // ("me assaltaram 200", "me aumentou 100") the "me" may be the
        // victim, not the receiver: ask.
        if (_givingVerb.hasMatch(verb)) return MoneyDirection.incoming;
        found = MoneyDirection.unclear;
        continue;
      }
      if (_thingWithPrice.hasMatch(after)) found = MoneyDirection.unclear;
    }
    return found;
  }

  static bool _informalIncoming(String s) {
    if (_handedToMe(s) == MoneyDirection.incoming) return true;
    for (final m in _moneyArrives.allMatches(s)) {
      final after = s.substring(m.end);
      if (!_leftMyAccount.hasMatch(after.split(RegExp(r'[,.;]|\be\b')).first)) return true;
    }
    return _userEarned.hasMatch(s);
  }

  /// A third person paying: "o chefe pagou 180", "o inquilino transferiu o
  /// aluguel, 1350". "eu paguei"/"a gente pagou" are the user, and "o joão
  /// me mandou…" is read by what he sent ([_handedToMe]).
  static final _thirdPersonPays = RegExp(
    r'\b(?!eu\b|gente\b|nos\b|que\b|me\b|te\b|lhe\b|se\b)[a-z]+\s+(pagou|pagaram|depositou|depositaram|transferiu|transferiram|'
    r'mandou|mandaram|acertou|acertaram|pixou|caiu|cairam|enviou|enviaram|reembolsou|reembolsaram|devolveu|devolveram|'
    r'restituiu|estornou|estornaram|repassou|repassaram)\b',
  );

  /// What a third person paid, as a signal: incoming when an amount follows
  /// within a few words; a conflict when they paid something of *mine* ("meu
  /// pai pagou minha conta de luz de 150") — no money of mine moved, so ask;
  /// outgoing when they *sent* a bill ("a loja mandou a fatura de 300"); null
  /// when no amount is named ("a maria pagou o almoço").
  static MoneyDirection? _thirdPartyPayment(String s) {
    for (final m in _thirdPersonPays.allMatches(s)) {
      final after = s.substring(m.end);
      final amount = RegExp(r'(?:r\$\s*)?\d').firstMatch(after);
      if (amount == null) continue;
      final between = after.substring(0, amount.start);
      if (between.split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty).length > 6) continue;
      // Paid to someone else ("o joão repassou 50 pro pedro"), not to me.
      final rest = after.substring(amount.end).split(RegExp(r'[,;.]')).first;
      if (RegExp(r'\b(?:pr[ao]s?|para)\s+(?!mim\b)(?:o\s+|a\s+|os\s+|as\s+)?[a-z]').hasMatch(rest) && !RegExp(r'\b(?:pra|para)\s+mim\b').hasMatch(rest)) {
        continue;
      }
      if (RegExp(r'\b(?:minha|meu|minhas|meus)\b').hasMatch(between)) return MoneyDirection.conflict;
      if (RegExp(r'^(?:mand|envi)').hasMatch(m.group(1)!) && RegExp('^\\s+$_det$_charge\\b').hasMatch(between)) {
        return MoneyDirection.outgoing;
      }
      return MoneyDirection.incoming;
    }
    return null;
  }

  static final _weakIn = [
    RegExp(r'\b(?:honorarios|salario|quinzena|comissao|reembolso|rendimento|rendimentos|mesada|gorjeta\s+que\s+ganhei|'
        r'deposito|depositou|depositaram|recebido|recebida|recebidos)\b'),
    // "rolou um extra de 220", "um bico de 150" (not "no extra", the store).
    RegExp(r'\b(?:um|uma|de)\s+(?:extra|extrinha|bico|bicos|freela|freelas|trampo|corre|corres|bicozinho)\b'),
  ];

  // ── the amount hanging on a verb nobody classified ──

  /// First-person past verbs that carry an amount: "-ei" (arranjei, tirei),
  /// the "-i" of -er/-ir verbs (bati, vendi) and the plural ("mexemos 200
  /// com o tio do bar", "fechamos 300", ACC-C-015).
  static final _firstPersonPast = RegExp(r'^(?:[a-z]{2,}ei|[a-z]{2,}(?:[tdbmvr]i|gui)|[a-z]{3,}(?:amos|emos|emo|imos))$');
  static const _beforeNoun = {
    'no', 'na', 'nos', 'nas', 'em', 'pro', 'pra', 'do', 'da', 'de', 'o', 'a', 'os', 'as', 'um', 'uma', 'ao', 'num', 'numa', 'pelo', 'pela',
  };
  static const _notVerbs = {
    'volei', 'joquei', 'hoquei', 'ponei', 'safari', 'salami', 'tatami', 'origami', 'wasabi', 'audi', 'ferrari', 'jabuti',
  };

  /// Verbs of spending/using money that aren't in [_strongOut] but whose
  /// direction is plain ("pedi 30 de pizza", "deixei 50 no bar").
  static final _knownSpendingVerb = RegExp(
    r'^(?:pedi|almocei|jantei|lanchei|recarreguei|peguei|deixei|coloquei|botei|tomei|comi|bebi|assisti|viajei|aluguei|'
    r'reservei|investi|apliquei|depositei|transferi|mandei|rachei|dividi|perdi|apostei|emprestei|fechei|troquei|consertei|'
    r'levei|encomendei|adquiri|instalei|matriculei|parcelei|financiei|saquei|enchi|cortei|passei|usei|acertei|pixei|soltei|'
    r'doei|reformei|lavei|abasteci|joguei|chamei|contribui|guardei|economizei|juntei|separei|reservei|paguei|gastei|comprei)$',
  );

  /// What was done to earn it: "fazendo faxina", "vendendo roupa",
  /// "trabalhando de garçom", "de gorjeta", "de comissão".
  static final _earningContext = RegExp(
    // (A gerund has a stem: "mando", "lindo" are not "vendendo".)
    r'\b(?!quando\b|sendo\b|tendo\b|indo\b|vindo\b|lindo\b|gastando\b|pagando\b|comprando\b)[a-z]{3,}(?:ando|endo|indo)\b|'
    // ("dando aula/plantão": the one working gerund with a one-letter stem.)
    r'\bdando\b|'
    r'\b(?:gorjeta|gorjetas|comissao|comissoes|bico|bicos|freela|freelas|extra|cache|gratificacao|bonus|bonificacao|premio|'
    r'lucro|lucros|salario|venda|vendas|trampo|diaria|diarias|corrida|corridas|servico|servicos)\b',
  );

  /// Right after the amount, the work that earned it: "200 vendendo bolo",
  /// "250 dando aula", "80 reais cortando grama".
  static final _earnedByDoing = RegExp(
    r'^\s*(?:reais|real|conto|contos|pila|pilas)?\s*(?:so\s+)?'
    r'(?:dando\b|(?!quando\b|sendo\b|tendo\b|indo\b|vindo\b|lindo\b|gastando\b|pagando\b|comprando\b|apostando\b|'
    r'jogando\b|perdendo\b|andando\b|devendo\b)[a-z]{3,}(?:ando|endo|indo)\b)',
  );

  /// The verb the amount hangs on, when it is a first-person past verb
  /// nobody classified: the nearest such word before the first amount, in
  /// the same clause, at most 3 words away ("tirei uns 400", "arranjei uma
  /// grana de 150").
  static String? _unclassifiedVerbWithAmount(String s) {
    // The first number that isn't a date ("dia 9 tirei 85…", CHAOS-B-006).
    final amount = _firstAmount(s);
    if (amount == null) return null;
    final clause = s.substring(0, amount.start).split(RegExp(r'[,;:.!?]')).last;
    final words = clause.split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty).toList();
    for (var i = words.length - 1; i >= 0 && i >= words.length - 4; i--) {
      final w = words[i];
      if (!_firstPersonPast.hasMatch(w) || _notVerbs.contains(w)) continue;
      // After an article or preposition it's a name ("no Morumbi 30").
      if (i > 0 && _beforeNoun.contains(words[i - 1])) continue;
      if (_knownSpendingVerb.hasMatch(w)) return null;
      return w;
    }
    return null;
  }

  /// The first number of [s] that is not a day ("dia 9", "12/09").
  static RegExpMatch? _firstAmount(String s) {
    for (final m in RegExp(r'(?:r\$\s*)?\d[\d.,]*').allMatches(s)) {
      // (Both halves of "15/6": the "6" is the month, not an amount.)
      if (RegExp(r'\bdias?\s+$').hasMatch(s.substring(0, m.start)) ||
          RegExp(r'^/\d').hasMatch(s.substring(m.end)) ||
          RegExp(r'\d/$').hasMatch(s.substring(0, m.start))) {
        continue;
      }
      return m;
    }
    return null;
  }

  /// The amount handed *to someone else*: "devolvi 80 pro joão", "repassei
  /// 300 pra minha mãe", "adiantei 500 pro pedreiro" — whatever the verb, the
  /// money left the user (CHAOS-B-021). ("pra pagar…" is a purpose, not a
  /// receiver.)
  static final _toSomeone = RegExp(
      // (A time word may sit between: "devolvi 1350 anteontem pro joão",
      // "repassei 118 dia 28 do mês passado pro joão".)
      r'^\s*(?:reais|real|conto|contos|pila|pilas)?\s*(?:,\s*)?'
      r'(?:(?:hoje|ontem|anteontem|cedo|agora|ja|(?:a|de|pela|na)\s+(?:noite|tarde|manha)|(?:n[ao]\s+)?dia\s+\d{1,2}(?:\s+do\s+mes\s+(?:passado|retrasado))?|'
      r'(?:n[ao]\s+)?(?:segunda|terca|quarta|quinta|sexta|sabado|domingo)(?:\s+passad[ao])?|(?:semana|mes)\s+passad[ao])\s+(?:,\s*)?){0,2}'
      r'(?:pr[ao]s?|para\s+(?:o|a|os|as|meu|minha))\s+(?!mim\b)(?![a-z]+(?:ar|er|ir)\b)[a-z]');

  /// The amount moved *with* someone: "troquei 100 com o vizinho", "fiz um
  /// rolo de 200 com meu primo", "rolou 120 com o fornecedor" — the words
  /// don't say which side paid (ACC-B-013).
  static final _withSomeone = RegExp(
      r'^\s*(?:reais|real|conto|contos|pila|pilas)?\s*(?:,\s*)?com\s+(?:o|a|os|as|meu|minha|meus|minhas|um|uma|seu|sua)?\s*[a-z]{3,}');

  /// Verbs that are an exchange between two sides, not a direction.
  static final _exchangeVerb = RegExp(r'\b(?:troquei|trocamos|acertei|acertamos|mexi|zerei|negociei|movimentei|rolou|rolo|transacionei|fiz\s+um\s+rolo)\b');

  static bool _any(List<RegExp> patterns, String s) => patterns.any((p) => p.hasMatch(s));

  // A number within a few words after the signal (or inside it).
  static final _amountSoon = RegExp(r'^(?:\s+[a-z$]+){0,4}?\s*(?:r\$\s*)?\d');

  static bool _withAmount(List<RegExp> patterns, String s) {
    for (final p in patterns) {
      for (final m in p.allMatches(s)) {
        if (RegExp(r'\d').hasMatch(m.group(0)!) || _amountSoon.hasMatch(s.substring(m.end))) return true;
      }
    }
    return false;
  }

  /// A charge reaching the user or the user made to pay (see the class doc).
  static bool _userIsCharged(String s) {
    if (_chargeArrives.hasMatch(s) || _madeToPay.hasMatch(s)) return true;
    for (final m in _chargeHandedToMe.allMatches(s)) {
      if (!_payingVerb.hasMatch(m.group(1)!)) return true;
    }
    if (_handedToMe(s) == MoneyDirection.outgoing) return true;
    return _dueDay.hasMatch(s) && !_incomeNoun.hasMatch(s);
  }

  /// "ganhei 40 de desconto": a discount is money not paid, never money in
  /// (ACC-C-014) — taken out before reading who pays whom.
  static final _discount = RegExp(
    r'\b(?:ganhei|consegui|tive|peguei|levei|obtive|recebi|deram|me\s+deram|me\s+deu)\s+(?:um\s+|uns\s+)?'
    r'(?:(?:r\$\s*)?\d[\d.,]*\s*(?:reais|real|conto|contos|pila|pilas|%|por\s*cento)?\s+)?(?:de\s+)?(?:desconto|abatimento)\b',
  );

  /// [detect] from what the words say of who pays whom (a verb, a role, a
  /// charge) — not from vocabulary alone ("boleto", "do encanador"), which
  /// only leans a side. [EntryCertainty] takes only this as a fact told.
  static MoneyDirection detectStrong(String text) => detect(text, strongOnly: true);

  static MoneyDirection detect(String text, {bool strongOnly = false}) {
    final s = CategoryNameMatcher.foldAccents(text.toLowerCase()).replaceAll(_discount, ' ');
    final charged = _userIsCharged(s);
    final thirdParty = _thirdPartyPayment(s);
    if (thirdParty == MoneyDirection.conflict && !_any(_strongIn, s) && !_any(_strongOut, s)) return MoneyDirection.conflict;
    final strongIn = !charged && (_any(_strongIn, s) || thirdParty == MoneyDirection.incoming || _informalIncoming(s));
    final strongOut = _any(_strongOut, s) || charged || thirdParty == MoneyDirection.outgoing;
    if (strongIn && strongOut) {
      // The side that carries the amount is the entry; the other is a detail
      // ("comprei um tênis de 200 e ganhei uma meia", "recebi 300 e já paguei
      // o aluguel"). Amounts on both sides: ask.
      final inAmount = _withAmount(_strongIn, s), outAmount = _withAmount(_strongOut, s);
      if (inAmount && !outAmount) return MoneyDirection.incoming;
      if (outAmount && !inAmount) return MoneyDirection.outgoing;
      return MoneyDirection.conflict;
    }
    if (strongIn) return MoneyDirection.incoming;
    if (strongOut) return MoneyDirection.outgoing;
    if (strongOnly) return MoneyDirection.unknown;
    final first = _firstAmount(s);
    if (first != null) {
      final afterAmount = s.substring(first.end);
      if (_withSomeone.hasMatch(afterAmount) && (_exchangeVerb.hasMatch(s) || _unclassifiedVerbWithAmount(s) != null)) {
        return MoneyDirection.unclear;
      }
      if (_toSomeone.hasMatch(afterAmount) && _unclassifiedVerbWithAmount(s) != null) return MoneyDirection.outgoing;
      // "fiz 200 vendendo bolo na feira", "tirei 118 vendendo trufa no
      // Hortifruti": the amount followed by the work that earned it is money
      // in, whatever the verb and the place — the place's category made the
      // classifier call it a purchase (CHAOS-B-006, found again in 7d).
      // ("perdi 200 apostando", "deixei 30 jogando sinuca": a spending verb
      // before the amount.)
      if (_earnedByDoing.hasMatch(afterAmount)) {
        final before = s.substring(0, first.start).split(RegExp(r'[^a-z]+')).where((w) => w.isNotEmpty);
        if (before.isEmpty || !_knownSpendingVerb.hasMatch(before.last)) return MoneyDirection.incoming;
      }
    }
    final weakIn = _any(_weakIn, s), weakOut = _any(_weakOut, s);
    if (weakOut && !weakIn) return MoneyDirection.outgoing;
    // The amount hangs on a verb nobody classified ("arranjei 150", "bati
    // 300"): what was done for it decides, or César asks (ACC-A-001/011).
    if (_unclassifiedVerbWithAmount(s) != null) {
      return (weakIn || _earningContext.hasMatch(s)) ? MoneyDirection.incoming : MoneyDirection.unclear;
    }
    if (weakIn && !weakOut) return MoneyDirection.incoming;
    if (_handedToMe(s) == MoneyDirection.unclear) return MoneyDirection.unclear;
    return MoneyDirection.unknown;
  }
}
