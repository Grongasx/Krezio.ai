import 'cesar_text.dart';

/// A conversational reply that isn't about the data: greeting, thanks,
/// goodbye, "o que você sabe fazer?", "como eu apago um lançamento?".
class SmallTalkReply {
  final String kind; // greeting | thanks | farewell | help | howto | identity
  final String text;
  final String spokenText;
  const SmallTalkReply(this.kind, this.text, [String? spoken]) : spokenText = spoken ?? text;
}

/// Greetings, thanks and self-help, so César answers "oi", "obrigado!" and
/// "o que você sabe fazer?" like a person instead of "Não consegui
/// identificar essa transação". Pure and deterministic (variants are picked
/// by a hash of the text; the time of day comes from [now]).
class CesarSmallTalk {
  CesarSmallTalk._();

  static const capabilitiesText = 'Posso te ajudar com tudo isso, só conversando:\n'
      '- **Registrar**: "gastei 50 no mercado no pix", "recebi 3000 de salário", "comprei um tênis de 300 no crédito em 3x"\n'
      '- **Corrigir**: "não, foi 45", "esse era lazer", "foi ontem", "muda o valor do aluguel pra 1500"\n'
      '- **Apagar**: "apaga o uber de ontem", "exclui o último" (eu confirmo antes) — e "desfaz" volta atrás\n'
      '- **Perguntar**: "quanto gastei esse mês?", "qual meu maior gasto?", "tô no vermelho?", '
      '"quanto posso gastar por dia até o fim do mês?" — e depois "e no mês passado?"\n'
      '- **Planejar**: metas ("quero juntar 5000 para uma viagem"), orçamentos ("meu limite de lazer é 800"), '
      'categorias ("cria a categoria Pets"), "posso comprar um celular de 2000?"\n'
      '- **Lembrar**: contas a vencer, quem te deve, empréstimos ("emprestei 100 pro João")';

  static const _capabilitiesSpoken = 'Eu registro gastos e receitas, corrijo e apago lançamentos, desfaço o que fiz, '
      'respondo perguntas como quanto você gastou ou qual seu maior gasto, e cuido de metas, orçamentos, categorias e lembretes. '
      'É só falar naturalmente.';

  static final Map<RegExp, String> _howTo = {
    RegExp(r'\b(?:apag\w*|exclu\w*|delet\w*|remov\w*|tirar)\b'):
        'É só me dizer qual: "apaga o uber de ontem", "exclui o último" ou "apaga os dois últimos". '
            'Eu mostro o que vou apagar e só apago depois do seu "sim". Se mudar de ideia, diga "desfaz".',
    RegExp(r'\b(?:desfa\w*|voltar\s+atras)\b'): 'Diga "desfaz" ou "volta atrás": eu desfaço a última coisa que fiz — lançar, mudar ou apagar.',
    RegExp(r'\b(?:edit\w*|mud\w*|alter\w*|corrig\w*|troc\w*|arrum\w*|consert\w*)\b'):
        'Logo depois de lançar, é só corrigir falando: "não, foi 45", "esse era lazer", "foi ontem", "foi no débito". '
            'Para qualquer outro lançamento, diga qual: "muda o valor do aluguel pra 1500" ou "o mercado de ontem foi no débito".',
    RegExp(r'\b(?:categoria\w*)\b'):
        'Diga "cria a categoria Pets com limite de 200", "renomeia a categoria Pets para Animais" ou "apaga a categoria Pets". '
            'Para mudar a categoria de um lançamento: "esse era lazer".',
    RegExp(r'\b(?:orcamento\w*|limite\w*)\b'): 'Diga "meu limite de lazer é 800 por mês". Depois pergunte "quanto ainda posso gastar com lazer?".',
    RegExp(r'\b(?:meta\w*|guardar|juntar|economizar)\b'):
        'Diga "quero juntar 5000 para uma viagem até dezembro". Depois, "guardei 200 na viagem" e "quanto falta pra minha meta?".',
    RegExp(r'\b(?:receita\w*|salario|entrada\w*|ganho\w*)\b'): 'É só falar: "recebi 3000 de salário" ou "caiu 500 de freela no pix".',
    RegExp(r'\b(?:emprest\w*|lembrete\w*|cobr\w*)\b'): 'Diga "emprestei 100 pro João, ele me paga dia 10" — eu anoto e te lembro de cobrar.',
    RegExp(r'\b(?:consult\w*|ver|vejo|saber|pergunt\w*|relatorio\w*|extrato)\b'):
        'Pergunte do seu jeito: "quanto gastei esse mês?", "qual meu maior gasto?", "quais foram meus últimos lançamentos?", '
            '"quanto gastei no pix?". Depois dá para emendar: "e no mês passado?".',
    RegExp(r'\b(?:registr\w*|lanc\w*|anot\w*|adicion\w*|cadastr\w*|gasto\w*|despesa\w*|colocar)\b'):
        'É só me contar como falaria com alguém: "gastei 50 no mercado no pix", "paguei 120 de luz no boleto", '
            '"comprei um tênis de 300 no crédito em 3x". Se faltar algo, eu pergunto.',
  };

  /// Reply for [text], or null when it isn't small talk.
  static SmallTalkReply? reply(String text, {DateTime? now}) {
    final s = CesarText.simplify(text).replaceAll(RegExp(r'\bcesar\b'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) {
      return const SmallTalkReply('greeting', 'Oi! Tô aqui. Quer registrar um gasto ou saber como estão suas finanças?');
    }
    final hour = (now ?? DateTime.now()).hour;
    final salute = hour < 12 ? 'Bom dia' : (hour < 18 ? 'Boa tarde' : 'Boa noite');

    // "como eu apago um lançamento?", "como faço pra criar uma meta?"
    // "como" + a first-person verb of an action, anywhere: "se eu errar um
    // valor, como conserto?", "e pra apagar, como faz?".
    final isHowTo = !RegExp(r'\d').hasMatch(s) &&
        (RegExp(r'^(?:e\s+)?como\s+(?:eu\s+|que\s+eu\s+|a\s+gente\s+|faco\s+|faz\s+|posso\s+|consigo\s+|devo\s+|se\s+|'
                    r'(?:apag|exclu|delet|remov|edit|mud|alter|corrij|corrig|consert|arrum|desfa|registr|lanc|cri|anot|adicion|cadastr|defin|coloc|vej|ve\b)\w*)')
                .hasMatch(s) ||
            RegExp(r'\bcomo\s+(?:(?:eu|que\s+eu|a\s+gente|faco\s+pra|faz\s+pra|faco\s+para|posso|consigo|devo)\s+)?'
                    r'(?:apag|exclu|delet|remov|edit|mud|alter|corrij|corrig|conserto|consert|arrum|desfa|registr|lanc|anot|adicion|cadastr)\w*')
                .hasMatch(s) ||
            RegExp(r'\b(?:pra|para)\s+(?:apagar|excluir|corrigir|consertar|arrumar|mudar|editar|desfazer|registrar|lancar)\b.*\bcomo\s+(?:faz|faco|que\s+faz)\b').hasMatch(s));
    if (isHowTo) {
      for (final e in _howTo.entries) {
        if (e.key.hasMatch(s)) return SmallTalkReply('howto', e.value);
      }
    }

    // "cê faz o quê?", "você serve pra quê?", "o que cê sabe fazer?": the
    // assistant as subject + do/know/serve + "o quê".
    if (RegExp(r'^(?:e\s+)?(?:(?:voce|vc|tu|ce|oce)\s+)(?:faz|sabe\s+fazer|consegue\s+fazer|serve|serve\s+pra|serve\s+para|pode\s+fazer)\s+(?:o\s+)?(?:que|oque)(?:\s+(?:exatamente|mesmo|afinal))?$|'
            r'^(?:e\s+)?(?:que|o\s+que)\s+(?:(?:voce|vc|tu|ce|oce)\s+)(?:faz|sabe\s+fazer|consegue\s+fazer)(?:\s+(?:exatamente|mesmo|afinal))?$')
        .hasMatch(s)) {
      return const SmallTalkReply('help', capabilitiesText, _capabilitiesSpoken);
    }

    if (RegExp(r'^(?:(?:e\s+)?o\s+que\s+(?:(?:voce|vc|tu)\s+)?(?:sabe|consegue|pode|faz|fazes)(?:\s+fazer)?|'
            r'(?:me\s+)?ajuda(?:\s+ai)?|socorro|help|comandos|quais\s+(?:sao\s+)?(?:os\s+|seus\s+)?comandos|'
            r'como\s+(?:voce|vc|tu)\s+funciona|como\s+funciona(?:\s+isso|\s+o\s+app)?|como\s+(?:te\s+)?us(?:o|ar)(?:\s+voce)?|'
            r'o\s+que\s+(?:eu\s+)?posso\s+(?:te\s+)?(?:falar|pedir|perguntar|dizer)|para\s+que\s+(?:voce|vc)\s+serve|pra\s+que\s+(?:voce|vc)\s+serve)$')
        .hasMatch(s)) {
      return const SmallTalkReply('help', capabilitiesText, _capabilitiesSpoken);
    }

    if (RegExp(r'^(?:quem\s+(?:e|eh)\s+(?:voce|vc|tu)|qual\s+(?:e\s+)?(?:o\s+)?seu\s+nome|como\s+(?:voce|vc)\s+se\s+chama|voce\s+e\s+(?:um\s+)?robo|voce\s+e\s+uma?\s+ia)$').hasMatch(s)) {
      return const SmallTalkReply('identity',
          'Eu sou o César, o copiloto financeiro do Krezio.ai. Funciono 100% no seu aparelho: seus dados não saem daqui. '
              'Pergunte "o que você sabe fazer?" para ver tudo que eu faço.');
    }

    const thanksWords = r'(?:muito\s+)?(?:obrigad[oa]|obrigadao|obrigadinh[oa]|brigad[oa]|valeu|vlw|obg|brigadao|agradecid[oa]|thanks|thank\s+you|show|top|perfeito)';
    if (RegExp('^$thanksWords(?:\\s+(?:mesmo|demais|viu|pela\\s+ajuda|por\\s+tudo|ai|parceiro|amigo|meu\\s+caro))*\$').hasMatch(s) &&
        !RegExp(r'^(?:show|top|perfeito)$').hasMatch(s)) {
      const variants = [
        'Por nada! Tô sempre por aqui. 😊',
        'Imagina! Qualquer coisa, é só chamar.',
        'De nada! Suas finanças agradecem. 💚',
      ];
      return SmallTalkReply('thanks', variants[CesarText.pick(s, variants.length)]);
    }

    if (RegExp(r'^(?:tchau|xau|ate\s+mais|ate\s+logo|ate\s+amanha|falou|flw|fui|boa\s+noite\s+e\s+ate\s+amanha|ate)$').hasMatch(s)) {
      return const SmallTalkReply('farewell', 'Até mais! Quando precisar, é só chamar. 👋');
    }

    final greeting = RegExp(r'^(?:oi+|ola|ole|opa|eai|e\s+ai|fala|salve|hey|ei|bom\s+dia|boa\s+tarde|boa\s+noite|oi\s+oi|alo)'
            r'(?:\s+(?:tudo\s+(?:bem|bom|certo|joia|tranquilo|ok|em\s+cima)|como\s+(?:vai|voce\s+esta|vc\s+ta|esta|ta)|beleza|blz|td\s+bem|tranquilo))?'
            r'(?:\s+(?:e\s+(?:voce|vc|ai)))?$')
        .firstMatch(s);
    final howAreYou = RegExp(r'^(?:tudo\s+(?:bem|bom|certo|joia|tranquilo)|como\s+(?:vai|voce\s+esta|vc\s+ta|voce\s+ta|esta\s+voce)|td\s+bem|beleza|blz)(?:\s+(?:com\s+)?(?:voce|vc))?$')
        .hasMatch(s);
    if (greeting != null || howAreYou) {
      final asked = RegExp(r'tudo|como\s+vai|como\s+(?:voce|vc)|td\s+bem|beleza|blz').hasMatch(s);
      final opener = RegExp(r'^bom\s+dia').hasMatch(s)
          ? 'Bom dia!'
          : RegExp(r'^boa\s+tarde').hasMatch(s)
              ? 'Boa tarde!'
              : RegExp(r'^boa\s+noite').hasMatch(s)
                  ? 'Boa noite!'
                  : (howAreYou ? '' : '$salute!');
      final status = asked ? ' Tudo ótimo por aqui, e com você?' : '';
      const nexts = [
        ' Quer registrar um gasto ou saber como estão suas finanças?',
        ' Me conta: lançar algo ou tirar alguma dúvida sobre seus gastos?',
      ];
      final text = '$opener$status${nexts[CesarText.pick(s, nexts.length)]}'.trim();
      return SmallTalkReply('greeting', text);
    }
    return null;
  }
}
