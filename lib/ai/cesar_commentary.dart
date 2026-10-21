import 'dart:math';

import '../backend/models/financial_transaction.dart';
import '../backend/repositories/financial_repository.dart';
import 'analytics/financial_profile.dart';
import 'cesar_text.dart';

/// What the user talks about: how it is said, which records are it, the
/// category whose budget covers it and a tip that helps with it.
class _Thing {
  final String name;
  final RegExp said;
  final RegExp? title;
  final String? category;
  final String emoji;
  final String budget;
  final String tip;
  _Thing(this.name, String said, this.emoji, this.budget, this.tip, {String? title, this.category})
      : said = RegExp(said),
        title = title == null ? null : RegExp(title);

  bool matches(FinancialTransaction t) =>
      (title != null && title!.hasMatch(CesarText.fold(t.title))) || (category != null && t.category == category);
}

/// A limit César offers to set ("sim" sets it).
typedef LimitOffer = ({String category, String name, double limit, double old});

class CommentReply {
  final String text;
  final String spokenText;
  final String route;
  final LimitOffer? limitOffer;
  const CommentReply(this.text, this.route, {String? spoken, this.limitOffer}) : spokenText = spoken ?? text;
}

/// What the user says about money that is neither an entry nor a question:
/// a complaint ("a gasolina subiu de novo, absurdo"), a worry ("acho que tô
/// gastando muito com uber"), a resolution ("preciso parar de pedir ifood"),
/// a plan ("amanhã vou no mercado"), a mood ("que semana difícil"), the
/// salary that doesn't last. César used to open an entry and ask "quanto
/// você gastou?"; now he answers like someone who knows the numbers — the
/// user's own spending on that thing, against their average — and offers
/// what helps (a limit, a reminder, a plan). Nothing is recorded.
///
/// Only sentences without a number and without an entry verb are taken
/// ("gastei 40 no uber" is an entry; "gastei demais no uber" is a worry).
/// Pure Dart.
class CesarCommentary {
  final FinancialRepository repository;
  final DateTime now;
  CesarCommentary({required this.repository, required this.now});

  static final List<_Thing> _things = [
    _Thing('combustível', r'\b(?:gasolina|etanol|alcool|combustivel|diesel|posto|abastecer)\b', '⛽', 'transport',
        'Pneus calibrados e abastecer onde o app do posto dá desconto ajudam a gastar menos.',
        title: r'\b(?:posto|gasolina|etanol|combustivel|shell|ipiranga|petrobras|br|ale|abasteci\w*)\b'),
    _Thing('Uber e corridas', r'\b(?:uber|99|taxi|corridas?|mototaxi)\b', '🚗', 'transport',
        'Nos trajetos de sempre, ônibus, metrô ou carona saem bem mais em conta.',
        title: r'\b(?:uber|99|99\s*pop|taxi|cabify|indrive|mototaxi)\b'),
    _Thing('delivery', r'\b(?:ifood|delivery|rappi|aiqfome|ze\s+delivery|pedir\s+comida|pedidos?\s+de\s+comida|lanche\s+por\s+app)\b', '🛵',
        'leisure', 'Cozinhar 2 ou 3 vezes a mais por semana costuma cortar metade do gasto com delivery.',
        title: r'\b(?:ifood|i\s*food|rappi|delivery|aiqfome|ze\s+delivery|uber\s+eats)\b'),
    _Thing('mercado', r'\b(?:mercado|supermercado|compras\s+do\s+mes|feira|atacad\w+|sacolao|hortifruti)\b', '🛒', 'supermarket',
        'Ir com lista e preferir marcas próprias costuma baixar a conta em 10 a 15%.',
        category: 'supermarket'),
    _Thing('conta de luz', r'\b(?:luz|energia|enel|cemig|cpfl|light|copel|celesc|coelba)\b', '💡', 'housing',
        'Chuveiro elétrico e ar-condicionado são os maiores vilões da conta de luz.',
        title: r'\b(?:luz|energia|enel|cemig|cpfl|light|copel|celesc|coelba|eletropaulo|equatorial|neoenergia)\b'),
    _Thing('conta de água', r'\b(?:agua|sabesp|copasa|sanepar|cedae)\b', '💧', 'housing',
        'Banhos mais curtos e conferir vazamentos fazem diferença na conta de água.',
        title: r'\b(?:agua|sabesp|copasa|sanepar|cedae|saae)\b'),
    _Thing('aluguel', r'\baluguel\b', '🏠', 'housing',
        'Na renovação do contrato vale negociar o reajuste: muito proprietário aceita para não ficar com o imóvel vazio.',
        title: r'\baluguel\b'),
    _Thing('internet e celular', r'\b(?:internet|wifi|net|celular|plano\s+de\s+celular|telefone)\b', '📶', 'housing',
        'Vale ligar na operadora e pedir um plano menor: costumam oferecer desconto para não perder o cliente.',
        title: r'\b(?:internet|vivo|claro|tim|oi|net|wifi|celular|telefone)\b'),
    _Thing('assinaturas', r'\b(?:netflix|spotify|disney|hbo|max|prime\s+video|amazon\s+prime|globoplay|streaming|assinaturas?)\b', '📺',
        'leisure', 'Revezar os streamings (um por mês) mantém a diversão e corta o custo.',
        title: r'\b(?:netflix|spotify|prime|disney|hbo|max|globoplay|deezer|youtube|apple\s+tv|paramount|crunchyroll)\b'),
    _Thing('farmácia', r'\b(?:farmacia|remedios?|drogaria)\b', '💊', 'health',
        'Genéricos e o desconto por CPF das farmácias ajudam bastante.',
        title: r'\b(?:farmacia|drogaria|drogasil|droga\s+raia|pague\s+menos|panvel|pacheco|remedios?)\b'),
    _Thing('padaria', r'\b(?:padaria|pao|paozinho|padoca)\b', '🥖', 'supermarket',
        'Pequenos gastos de todo dia somam: R\$ 10 por dia viram R\$ 300 no mês.',
        title: r'\b(?:padaria|pao|panificadora|padoca)\b'),
    _Thing('café', r'\b(?:cafe|cafezinho|cafeteria|starbucks)\b', '☕', 'leisure',
        'Pequenos gastos de todo dia somam: R\$ 10 por dia viram R\$ 300 no mês.',
        title: r'\b(?:cafe|cafeteria|starbucks)\b'),
    _Thing('lazer', r'\b(?:lazer|role|balada|bares?|barzinho|happy\s+hour|cerveja|saidas?|sair\s+a\s+noite)\b', '🎉', 'leisure',
        'Definir um valor por saída ajuda a curtir sem culpa.',
        category: 'leisure'),
  ];

  // ───────────────────────── detection ─────────────────────────

  static final _question = RegExp(r'^(?:quanto|quantos|quantas|qual|quais|como|quando|onde|cade|por\s*que|o\s+que|me\s+(?:mostra|diz|fala))\b');
  static final _entryVerb = RegExp(r'\b(?:gastei|gastamos|paguei|pagamos|comprei|compramos|recebi|ganhei|transferi|torrei|abasteci|depositei|pedi|almocei|jantei|lanchei)\b');
  static final _intensity = RegExp(r'\b(?:gast(?:ei|amos)|torrei|pedi)\s+(?:muito|demais|horrores|pra\s+caramba|um\s+absurdo|uma\s+fortuna)\b');
  static final _requests = RegExp(r'\bme\s+(?:lembra|lembre|avisa|avise)\b|\b(?:cria|crie|coloca|coloque|define|defina|registra|registre|anota|anote|apaga|apague)\b');

  static final _priceUp = RegExp(r'\b(?:subiu|subiram|aumentou|aumentaram|disparou|dispararam|encareceu|so\s+sobe|ta\s+subindo|vive\s+subindo)\b');
  static final _cameHigh = RegExp(r'\b(?:veio|vieram|chegou|chegaram)\s+(?:muito\s+|bem\s+|super\s+)?(?:alt[oa]s?|absurd[oa]s?|salgad[oa]s?|car[oa]s?|pesad[oa]s?)\b');
  static final _expensive = RegExp(r'\b(?:car[oa]s?|carissim[oa]s?|absurd[oa]s?|salgad[oa]s?)\b|\bum\s+roubo\b|\bpela\s+hora\s+da\s+morte\b|\bos\s+olhos\s+da\s+cara\b');
  static final _worry = RegExp(r'\b(?:to|tou|estou|ando|tamo|estamos|tava|estava)\s+gastando\s+(?:muito|demais|horrores|pra\s+caramba|um\s+absurdo)\b|'
      r'\b(?:gast(?:ei|amos)|torrei|pedi)\s+(?:muito|demais|horrores|pra\s+caramba|um\s+absurdo|uma\s+fortuna)\b|\bexager(?:ei|amos|ando)\b|'
      r'\b(?:reclam\w+|diz|disse|fala|falou|acha|achou)\s+que\s+(?:eu\s+)?gasto\s+(?:muito|demais)\b|\bgasto\s+(?:muito|demais)\s+com\b|'
      // "acho que o ifood tá me quebrando"
      r'\b(?:ta|esta|vai)\s+me\s+(?:quebrando|falindo|matando|arruinando|quebrar|falir|levar\s+a\s+falencia)\b');
  static final _resolve = RegExp(r'\b(?:preciso|precisava|tenho\s+que|tenho\s+de|vou|quero|queria|devia|deveria|bora)\s+(?:(?:tentar|comecar\s+a)\s+)?'
      r'(?:parar\s+de\s+(?:gastar|pedir|comprar|usar|ir|torrar)|cortar|reduzir|diminuir|segurar|maneirar|gastar\s+menos|largar)\b');
  static final _noSpend = RegExp(r'\b(?:hoje|essa\s+semana|esse\s+mes|este\s+mes|amanha)\s+(?:eu\s+)?(?:nao\s+vou|vou\s+tentar\s+nao|to\s+proibid[oa]\s+de|nao\s+posso)\s+gastar\b|'
      r'\b(?:dia|semana)\s+sem\s+gastar\b|\bvou\s+ficar\s+sem\s+gastar\b');
  static final _plan = RegExp(r'^(?:(?:e|entao|bom|ah)\s+)?(?:amanha|depois|mais\s+tarde|hoje\s+(?:a\s+noite|mais\s+tarde|de\s+tarde|a\s+tarde)|'
      r'(?:no|nesse|neste)\s+fim\s+de\s+semana|sabado|domingo|segunda|terca|quarta|quinta|sexta|semana\s+que\s+vem|mes\s+que\s+vem|daqui\s+a\s+pouco)\s+'
      r'(?:eu\s+)?(?:vou|vamos|tenho\s+que|preciso|pretendo|quero)\b');
  static final _salaryShort = RegExp(r'\b(?:salario|grana|dinheiro|renda)\s+(?:nao|nunca|mal)\s+(?:da|chega|rende|dura)\b|\bnao\s+sobra\s+nada\b|\bnunca\s+sobra\b|'
      r'\b(?:salario|dinheiro)\s+(?:acaba|some)\s+(?:rapido|logo|antes)\b');
  static final _wantMore = RegExp(r'\b(?:queria|quero|preciso|precisava)\s+(?:ganhar|faturar|receber)\s+mais\b|\b(?:queria|quero|preciso)\s+(?:de\s+)?(?:uma\s+)?renda\s+extra\b');
  static final _payday = RegExp(r'\b(?:hoje|amanha)\s+(?:e|eh|e\s+o)\s+dia\s+(?:de\s+)?(?:pagamento|receber|salario|pagar\s+o\s+pessoal)\b|^(?:oba\s+)?dia\s+de\s+pagamento\b');
  static final _moodWeek = RegExp(r'\b(?:semana|dia)\s+(?:dificil|puxad[oa]|pesad[oa]|complicad[oa]|apertad[oa]|tens[oa]|osso|cansativ[oa])\b|'
      r'\b(?:essa|esta|a)\s+semana\s+(?:foi|ta|esta|tava)\s+(?:dificil|puxada|pesada|complicada|apertada|osso|tensa)\b');
  static final _moodMonth = RegExp(r'\b(?:esse|este|o)\s+mes\s+(?:foi|ta|esta|tava)\s+(?:dificil|puxado|pesado|complicado|apertado|osso|tenso)\b|'
      r'\bmes\s+(?:dificil|puxado|pesado|complicado|apertado)\b|\b(?:que\s+caro\s+(?:ta|esta)\s+tudo|(?:ta|esta)\s+tudo\s+(?:muito\s+|tao\s+)?caro|tudo\s+(?:ta|esta)\s+(?:muito\s+)?caro)\b|'
      r'\b(?:a\s+vida|as\s+coisas|tudo)\s+(?:ta|esta|anda|tao|estao)\s+(?:muito\s+|tao\s+|cada\s+vez\s+mais\s+|bem\s+)?car[ao]s?\b|'
      r'\b(?:to|tou|estou|vou\s+ficar|fico)\s+(?:ferrad[oa]|lascad[oa]|quebrad[oa]|na\s+pior)\b');
  static final _dollar = RegExp(r'\b(?:dolar|euro|cambio)\b');
  static final _positive = RegExp(r'\b(?:tava|estava|foi|ta|esta)\s+(?:muito\s+|bem\s+|super\s+)?(?:otim[oa]|boa|bom|legal|top|show|incrivel|maravilhos[oa]|uma\s+delicia|delicios[oa]|barat[oa]|em\s+conta)\b');
  static final _hate = RegExp(r'\b(?:odeio|detesto|nao\s+suporto|nao\s+aguento(?:\s+mais)?|que\s+raiva\s+de)\b');
  static final _control = RegExp(r'\b(?:preciso|quero|tenho\s+que|queria|vou|devia|deveria|bora)\s+(?:me\s+)?(?:controlar|organizar|cuidar\s+(?:melhor\s+)?d[oae]s?|acompanhar)\s+'
      r'(?:melhor\s+|mais\s+)?(?:(?:os|meus|o\s+meu|minhas|as|meu|minha)\s+)?(?:gastos|dinheiro|financas|grana|contas|despesas)\b');
  static final _bills = RegExp(r'\b(?:boletos?|contas?|faturas?|impostos?|taxas?|ipva|iptu)\b');

  /// César's answer to [s] (simplified text) when it is a comment, or null.
  CommentReply? reply(String s, String original) {
    if (s.isEmpty || RegExp(r'\d').hasMatch(s) || _question.hasMatch(s) || _requests.hasMatch(s)) return null;
    if (_entryVerb.hasMatch(s) && !_intensity.hasMatch(s)) return null;
    final thing = _thingIn(s);
    // "tô gastando demais?", "tô no vermelho?": a yes/no question about the
    // month as a whole is the reports' (only one about a thing stays here).
    if (original.trim().endsWith('?') && thing == null) return null;

    if (_hate.hasMatch(s)) return _hateReply(s);
    if (_control.hasMatch(s)) return _controlReply();
    if (_worry.hasMatch(s)) return thing != null ? _worryAbout(thing, s) : _worryGeneral(s);
    if (_noSpend.hasMatch(s)) return _noSpendReply();
    if (_resolve.hasMatch(s) && thing != null) return _resolution(thing);
    if (_salaryShort.hasMatch(s)) return _salaryShortReply();
    if (_wantMore.hasMatch(s)) return _wantMoreReply();
    if (_payday.hasMatch(s)) return _paydayReply();
    if (thing != null && (_priceUp.hasMatch(s) || _cameHigh.hasMatch(s) || _expensive.hasMatch(s)) && !_moodMonth.hasMatch(s)) {
      return _complaint(thing, s);
    }
    if (_plan.hasMatch(s)) return _planReply(s, thing);
    if (_moodWeek.hasMatch(s)) return _weekMood();
    if (_moodMonth.hasMatch(s) || (_dollar.hasMatch(s) && RegExp(r'\b(?:subir|subiu|ferrad[oa]|lascad[oa])\b').hasMatch(s))) {
      return _dollar.hasMatch(s) ? _reserveReply() : _monthMood();
    }
    if (_positive.hasMatch(s) && (thing != null || RegExp(r'\b(?:loja|shopping|restaurante|passeio|viagem|compra|promocao)\b').hasMatch(s))) {
      return _positiveReply();
    }
    return null;
  }

  _Thing? _thingIn(String s) {
    for (final t in _things) {
      if (t.said.hasMatch(s)) return t;
    }
    return null;
  }

  // ───────────────────────── numbers ─────────────────────────

  DateTime get _today => DateTime(now.year, now.month, now.day);
  bool _inMonth(FinancialTransaction t, DateTime m) => t.date.year == m.year && t.date.month == m.month;
  Iterable<FinancialTransaction> get _expenses =>
      repository.transactions.where((t) => t.type == TransactionType.expense && !t.date.isAfter(_today.add(const Duration(days: 1))));

  late final FinancialProfile _profile = FinancialProfile.build(repository.transactions, now: now);

  /// This month's total and count for [thing], and its average over the last
  /// full months (up to 3; 0 when there is no full month yet).
  ({double month, int count, double avg, List<FinancialTransaction> all}) _stats(_Thing thing) {
    final all = _expenses.where(thing.matches).toList()..sort((a, b) => b.date.compareTo(a.date));
    final cur = all.where((t) => _inMonth(t, now));
    final full = _profile.months.map((m) => m.month).toList();
    final recent = full.length > 3 ? full.sublist(full.length - 3) : full;
    final avg = recent.isEmpty
        ? 0.0
        : recent.map((m) => all.where((t) => _inMonth(t, m)).fold(0.0, (a, t) => a + t.amount)).reduce((a, b) => a + b) / recent.length;
    return (month: cur.fold(0.0, (a, t) => a + t.amount), count: cur.length, avg: avg, all: all);
  }

  double get _monthSpent => _expenses.where((t) => _inMonth(t, now)).fold(0.0, (a, t) => a + t.amount);

  /// The categories that took the most this month, with their totals.
  List<({String name, double total})> _topCategories(int n) {
    final by = <String, double>{};
    for (final t in _expenses.where((t) => _inMonth(t, now))) {
      by[t.category] = (by[t.category] ?? 0) + t.amount;
    }
    final sorted = by.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in sorted.take(n)) (name: CesarText.categoryName(e.key, repository.budgets), total: e.value)];
  }

  static String _m(double v) => CesarText.money(v);
  static double _round(double v, double step) => (v / step).round() * step;

  String _versusAverage(double month, double avg) {
    if (avg <= 0) return '';
    final day = now.day, days = DateTime(now.year, now.month + 1, 0).day;
    final expectedSoFar = avg * day / days;
    if (month > avg) return ' Já passou da sua média de ${_m(avg)} por mês.';
    if (month > expectedSoFar * 1.15) return ' Sua média é ${_m(avg)} por mês, e este mês está num ritmo acima dela.';
    if (month < expectedSoFar * 0.85) return ' Sua média é ${_m(avg)} por mês: este mês está abaixo do seu normal. 👏';
    return ' Sua média é ${_m(avg)} por mês: este mês está no seu ritmo de sempre.';
  }

  /// A lower limit for the budget of [thing] that would hold half of what it
  /// usually costs — or null when it wouldn't change anything.
  LimitOffer? _limitFor(_Thing thing, double monthly) {
    final b = repository.budgets.where((b) => b.category == thing.budget).firstOrNull;
    if (b == null || monthly <= 0) return null;
    final base = b.monthlyLimit > 0 ? b.monthlyLimit : (_profile.categories[b.category]?.mean ?? 0);
    if (base <= 0) return null;
    final floor = (b.currentSpent / 50).ceil() * 50.0;
    final target = max(_round(base - monthly * 0.5, 50), floor);
    if (target <= 0 || target >= base - 25) return null;
    return (category: b.category, name: b.name, limit: target, old: b.monthlyLimit);
  }

  /// When no lower limit makes sense because this month already went past it.
  String _overNote(_Thing thing) {
    final b = repository.budgets.where((b) => b.category == thing.budget).firstOrNull;
    if (b == null || b.monthlyLimit <= 0 || !b.isOverBudget) return '';
    return '\n\n⚠️ Este mês você já passou do limite de **${b.name}**: ${_m(b.currentSpent)} de ${_m(b.monthlyLimit)}.';
  }

  String _offerText(LimitOffer o) => o.old > 0
      ? '\n\nQuer que eu baixe o limite de **${o.name}** de ${_m(o.old)} para **${_m(o.limit)}** por mês, pra te ajudar a segurar? (sim/não)'
      : '\n\nQuer que eu coloque um limite de **${_m(o.limit)}** por mês em **${o.name}**, pra te ajudar a segurar? (sim/não)';

  // ───────────────────────── replies ─────────────────────────

  CommentReply _complaint(_Thing thing, String s) {
    final st = _stats(thing);
    final opener = _cameHigh.hasMatch(s)
        ? 'Vixe, veio alta mesmo!'
        : _priceUp.hasMatch(s)
            ? 'Pois é, subiu mesmo!'
            : 'Tá salgado mesmo!';
    final parts = <String>[];
    final isBill = thing.budget == 'housing' && thing.name.startsWith('conta');
    final word = thing.name.replaceFirst('conta de ', '');
    if (isBill && st.all.isNotEmpty) {
      // A bill: the last one registered against the ones before it — the
      // new one may not be registered yet.
      final last = st.all.first;
      final before = st.all.skip(1).take(6).map((t) => t.amount).toList();
      final avg = before.isEmpty ? 0.0 : before.reduce((a, b) => a + b) / before.length;
      final thisMonth = _inMonth(last, now);
      parts.add('A última ${thing.name} que você registrou foi de **${_m(last.amount)}** (${CesarText.ddmm(last.date)})');
      if (avg > 0) {
        final diff = last.amount / avg - 1;
        parts.add(diff > 0.05
            ? ', ${(diff * 100).round()}% acima da média das anteriores (${_m(avg)}).'
            : diff < -0.05
                ? ', abaixo da média das anteriores (${_m(avg)}).'
                : ', parecida com as anteriores (${_m(avg)}).');
      } else {
        parts.add('.');
      }
      if (!thisMonth) parts.add(' Se a deste mês já chegou, me diga o valor (ex.: "paguei 230 de $word no boleto") que eu anoto e comparo.');
    } else if (isBill) {
      parts.add('Ainda não tenho nenhuma ${thing.name} registrada. Me diga o valor (ex.: "paguei 120 de $word no pix") que eu anoto e passo a comparar '
          'com as próximas.');
    } else if (thing.name == 'aluguel' && st.all.isNotEmpty) {
      final rent = st.all.first.amount;
      final income = _profile.avgIncome;
      parts.add('Seu aluguel é de **${_m(rent)}**');
      if (income > 0) {
        final share = rent / income;
        parts.add(' — ${(share * 100).round()}% do que entra por mês. '
            '${share > 0.3 ? 'O recomendado é até 30%, então ele pesa mesmo.' : 'Está dentro do recomendado (até 30%).'}');
      } else {
        parts.add('.');
      }
    } else if (st.month > 0 || st.avg > 0) {
      parts.add('Este mês você já gastou **${_m(st.month)}** com ${thing.name}${st.count > 1 ? ' (${st.count} vezes)' : ''}.');
      parts.add(_versusAverage(st.month, st.avg));
    } else {
      parts.add('Ainda não vi gastos seus com ${thing.name} por aqui — quando rolar, me conta o valor que eu anoto e acompanho pra você.');
    }
    final body = parts.join();
    final t = '${thing.emoji} $opener $body\n\n💡 ${thing.tip}';
    return CommentReply(t, 'comment:complaint', spoken: '$opener ${body.replaceAll('**', '')}');
  }

  CommentReply _worryAbout(_Thing thing, String s) {
    final st = _stats(thing);
    if (st.month <= 0 && st.avg <= 0) {
      final t = 'Pelos seus registros, ainda não tem gasto com ${thing.name} por aqui. Se tiver gastos que não anotou, me conta o valor que eu registro e '
          'te mostro o total. ${thing.emoji}';
      return CommentReply(t, 'comment:worry');
    }
    final total = _monthSpent;
    final share = st.avg <= 0 && total > 0 && st.month > 0
        ? ' Isso é ${(st.month / total * 100).round()}% de tudo o que você gastou no mês${st.month / total < 0.05 ? ' — pouco perto do resto' : ''}.'
        : '';
    final body = 'Vamos aos números: este mês foram **${_m(st.month)}** com ${thing.name}${st.count > 0 ? ' em ${st.count} ${st.count == 1 ? 'vez' : 'vezes'}' : ''}.'
        '${_versusAverage(st.month, st.avg)}$share';
    final offer = _limitFor(thing, st.avg > 0 ? st.avg : st.month);
    final t = '${thing.emoji} $body\n\n💡 ${thing.tip}${offer == null ? _overNote(thing) : _offerText(offer)}';
    return CommentReply(t, 'comment:worry', spoken: body.replaceAll('**', ''), limitOffer: offer);
  }

  CommentReply _worryGeneral(String s) {
    if (RegExp(r'\bfim\s+de\s+semana\b').hasMatch(s)) {
      // The last weekend (Saturday and Sunday), this one if it is under way.
      final back = now.weekday == DateTime.sunday ? 1 : (now.weekday == DateTime.saturday ? 0 : now.weekday + 1);
      final sat = _today.subtract(Duration(days: back));
      final sun = sat.add(const Duration(days: 1));
      final list = _expenses.where((t) {
        final d = DateTime(t.date.year, t.date.month, t.date.day);
        return d == sat || d == sun;
      }).toList()
        ..sort((a, b) => b.amount.compareTo(a.amount));
      if (list.isEmpty) {
        const t = 'No fim de semana não tem gasto anotado aqui. Se gastou e não registrou, me conta os valores que eu anoto. 🙂';
        return const CommentReply(t, 'comment:worry');
      }
      final total = list.fold(0.0, (a, t) => a + t.amount);
      final items = list.take(4).map((t) => '${t.title} (${_m(t.amount)})').join(', ');
      final t = 'No fim de semana você gastou **${_m(total)}**: $items${list.length > 4 ? ' e mais ${list.length - 4}' : ''}.\n\n'
          'Se quiser, eu acho onde dá pra cortar — pergunte "o que eu devo cortar?".';
      return CommentReply(t, 'comment:worry', spoken: 'No fim de semana você gastou ${_m(total)}.');
    }
    return _monthMood(opener: 'Vamos aos números 📊');
  }

  CommentReply _resolution(_Thing thing) {
    final st = _stats(thing);
    if (st.month <= 0 && st.avg <= 0) {
      final t = 'Boa decisão! 💪 Ainda não vi gastos com ${thing.name} por aqui. Se rolar, me conta o valor que eu anoto e acompanho com você.';
      return CommentReply(t, 'comment:resolution');
    }
    final monthly = st.avg > 0 ? st.avg : st.month * DateTime(now.year, now.month + 1, 0).day / max(1, now.day);
    final half = _round(monthly / 2, 5);
    final pace = st.avg > 0
        ? ', e sua média é ${_m(st.avg)} por mês'
        : (monthly > st.month + 1 ? ' — no ritmo atual, uns ${_m(_round(monthly, 5))} até o fim do mês' : '');
    final body = 'Boa decisão! 💪 Com ${thing.name} foram **${_m(st.month)}** este mês${st.count > 0 ? ' (${st.count} ${st.count == 1 ? 'vez' : 'vezes'})' : ''}'
        '$pace. Cortando pela metade, sobram uns **${_m(half)} por mês** — ${_m(half * 12)} por ano.';
    final offer = _limitFor(thing, monthly);
    final t = '${thing.emoji} $body\n\n💡 ${thing.tip}${offer == null ? _overNote(thing) : _offerText(offer)}';
    return CommentReply(t, 'comment:resolution', spoken: body.replaceAll('**', '').replaceAll(' 💪', ''), limitOffer: offer);
  }

  CommentReply _noSpendReply() {
    final today = _expenses.where((t) => t.date.year == now.year && t.date.month == now.month && t.date.day == now.day).fold(0.0, (a, t) => a + t.amount);
    final daily = _profile.dailyVariable.isEmpty ? 0.0 : _profile.dailyVariable.reduce((a, b) => a + b) / _profile.dailyVariable.length;
    final start = today > 0 ? 'Hoje você já registrou ${_m(today)} — daqui pra frente, zero!' : 'Hoje ainda não tem nenhum gasto anotado.';
    final avg = daily >= 1 ? ' Num dia normal você gasta uns ${_m(daily)}, então isso fica no seu bolso.' : '';
    final t = 'Desafio aceito! 💪 $start$avg Se escapar algo, me conta que eu anoto.';
    return CommentReply(t, 'comment:resolution', spoken: t.replaceAll(' 💪', ''));
  }

  CommentReply _salaryShortReply() {
    final p = _profile;
    if (!p.hasHistory || p.avgIncome <= 0) {
      const t = 'Te entendo 😕 Vamos montar um plano juntos? Diga "vamos dividir meu salário" que eu separo quanto vai para as contas, '
          'para o dia a dia e para guardar.';
      return const CommentReply(t, 'comment:income');
    }
    final fixed = p.recurringExpenseMonthly;
    final fixedPart = fixed > 0 ? ' Só os gastos fixos levam ${_m(fixed)} (${(fixed / p.avgIncome * 100).round()}% do que entra).' : '';
    final body = 'Pelos seus dados, entram uns **${_m(p.avgIncome)} por mês** e saem **${_m(p.avgExpense)}**.$fixedPart';
    final t = 'Te entendo 😕 $body\n\nQue tal montarmos um plano juntos? Diga "vamos dividir meu salário" que eu separo quanto vai para cada coisa, '
        'ou pergunte "o que eu devo cortar?".';
    return CommentReply(t, 'comment:income', spoken: 'Te entendo. ${body.replaceAll('**', '')}');
  }

  CommentReply _wantMoreReply() {
    const t = 'Quem não queria, né? 😄 Ideias que costumam funcionar: vender o que está parado em casa, freelas na sua área ou um bico no fim de semana. '
        'Quando entrar algo, me conta (ex.: "recebi 300 de freela") que eu registro.\n\nE enquanto isso eu te ajudo a fazer o dinheiro render — '
        'pergunte "o que eu devo cortar?".';
    return const CommentReply(t, 'comment:income');
  }

  CommentReply _paydayReply() {
    final fixed = _profile.recurringExpenseMonthly;
    final t = 'Oba, dia de pagamento! 🎉 Quando cair, me diga o valor (ex.: "recebi 3200 de salário") que eu registro'
        '${fixed > 0 ? ' — e lembre de separar uns ${_m(fixed)} para as contas fixas do mês' : ''}.';
    return CommentReply(t, 'comment:income', spoken: t.replaceAll(' 🎉', ''));
  }

  CommentReply _planReply(String s, _Thing? thing) {
    final pay = RegExp(r'\bpagar\s+(?:(?:o|a|os|as|meu|minha)\s+)?([a-z]+(?:\s+(?:de|do|da)\s+[a-z]+)?)').firstMatch(s);
    if (pay != null) {
      final what = pay.group(1)!;
      final label = const {'ipva': 'IPVA', 'iptu': 'IPTU'}[what] ?? what;
      final t = '📅 Quer que eu te lembre? Me diga o valor e o dia, por exemplo: "me lembra de pagar o $label de 500 dia 20". '
          'Assim ele aparece na sua agenda e eu te aviso antes.';
      return CommentReply(t, 'comment:plan', spoken: 'Quer que eu te lembre? Me diga o valor e o dia.');
    }
    if (thing != null) {
      final st = _stats(thing);
      final recent = st.all.take(5).toList();
      final ticket = recent.isEmpty ? 0.0 : recent.fold(0.0, (a, t) => a + t.amount) / recent.length;
      final b = repository.budgets.where((b) => b.category == thing.budget).firstOrNull;
      final parts = <String>[];
      if (ticket > 0) parts.add('Suas últimas idas deram em média **${_m(ticket)}**.');
      if (b != null && b.monthlyLimit > 0) {
        parts.add(b.isOverBudget
            ? 'Atenção: o orçamento de ${b.name} deste mês já estourou (${_m(b.currentSpent)} de ${_m(b.monthlyLimit)}).'
            : 'Ainda sobram **${_m(b.remaining)}** no orçamento de ${b.name} este mês.');
      }
      final t = 'Beleza! ${thing.emoji} ${parts.join(' ')}${parts.isEmpty ? '' : ' '}Quando voltar, me conta quanto deu que eu anoto.';
      return CommentReply(t, 'comment:plan', spoken: t.replaceAll('**', '').replaceAll(' ${thing.emoji}', ''));
    }
    const t = 'Beleza! Quando acontecer, me conta o valor que eu anoto. 🙂';
    return const CommentReply(t, 'comment:plan');
  }

  CommentReply _weekMood() {
    final monday = _today.subtract(Duration(days: now.weekday - 1));
    final week = _expenses.where((t) => !DateTime(t.date.year, t.date.month, t.date.day).isBefore(monday)).toList();
    final total = week.fold(0.0, (a, t) => a + t.amount);
    final by = <String, double>{};
    for (final t in week) {
      by[t.category] = (by[t.category] ?? 0) + t.amount;
    }
    final top = by.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final money = week.isEmpty
        ? 'No dinheiro, pelo menos, a semana está tranquila: nenhum gasto anotado desde segunda.'
        : 'No dinheiro, foi assim: desde segunda você gastou **${_m(total)}** em ${week.length} ${week.length == 1 ? 'lançamento' : 'lançamentos'}'
            '${top.isEmpty ? '' : ', mais com ${CesarText.categoryName(top.first.key, repository.budgets)}'}.';
    final t = 'Semana puxada, hein? 🫂 $money\n\nQuer ver o que vence nos próximos dias? Pergunte "o que tenho essa semana?".';
    return CommentReply(t, 'comment:mood', spoken: 'Semana puxada, hein? ${money.replaceAll('**', '')}');
  }

  CommentReply _monthMood({String opener = 'Tá puxado mesmo 😮‍💨'}) {
    final spent = _monthSpent;
    final avg = _profile.months.isEmpty ? 0.0 : _profile.avgExpense;
    final top = _topCategories(2);
    final vs = avg > 0 ? (spent > avg ? ', acima da sua média de ${_m(avg)} por mês' : '; sua média é ${_m(avg)} por mês') : '';
    final heavy = top.isEmpty ? '' : ' O que mais pesou: ${top.map((c) => '${c.name} (${_m(c.total)})').join(' e ')}.';
    final body = 'Este mês você já gastou **${_m(spent)}**$vs.$heavy';
    final t = '$opener $body\n\nQuer que eu veja onde dá pra cortar? Pergunte "o que eu devo cortar?".';
    return CommentReply(t, 'comment:mood', spoken: body.replaceAll('**', ''));
  }

  CommentReply _reserveReply() {
    final daily = _profile.avgExpense > 0 ? _profile.avgExpense / 30 : (_monthSpent / max(1, now.day));
    final days = daily > 0 ? (repository.totalBalance / daily).floor() : 0;
    final cover = days > 0 ? ' Hoje seu saldo cobre uns **$days dias** dos seus gastos.' : '';
    final t = 'Câmbio ninguém controla 😬 O que dá para controlar é a reserva.$cover\n\nQuer começar uma reserva de emergência? '
        'Diga, por exemplo, "quero juntar 3000 pra reserva" que eu monto a meta.';
    return CommentReply(t, 'comment:mood', spoken: 'Câmbio ninguém controla. O que dá para controlar é a reserva.${cover.replaceAll('**', '')}');
  }

  /// "preciso controlar melhor meus gastos": three simple steps, with the
  /// user's own numbers.
  CommentReply _controlReply() {
    final spent = _monthSpent;
    final withLimit = repository.budgets.where((b) => b.monthlyLimit > 0).toList();
    final over = withLimit.where((b) => b.isOverBudget).map((b) => b.name).toList();
    final limits = withLimit.isEmpty
        ? 'ainda não tem limites — diga, por exemplo, "meu limite de lazer é 400"'
        : 'tem ${withLimit.length} limites${over.isEmpty ? ', todos dentro por enquanto' : ' e já passou em ${over.join(' e ')}'} (pergunte "estou dentro do orçamento?")';
    final t = 'Bora! O jeito mais simples é:\n'
        '1. **Anotar tudo na hora** — é só me contar ("gastei 30 no uber no pix"); este mês já são ${_m(spent)} registrados.\n'
        '2. **Limite por categoria** — você $limits.\n'
        '3. **Uma olhada por semana** — pergunte "como foi minha semana?" ou "o que eu devo cortar?".\n\n'
        'Se quiser, monto o plano do mês com você: diga "vamos dividir meu salário".';
    return CommentReply('🧭 $t', 'comment:resolution',
        spoken: 'Bora! Anote tudo na hora, tenha um limite por categoria e dê uma olhada por semana. Se quiser, monto o plano do mês com você.');
  }

  CommentReply _positiveReply() {
    const t = 'Que bom! 😄 Se gastou algo, me diga o valor (ex.: "gastei 50 no pix") que eu anoto.';
    return const CommentReply(t, 'comment:positive');
  }

  CommentReply _hateReply(String s) {
    if (!_bills.hasMatch(s)) {
      const t = 'Te entendo 😅 Se quiser ajuda com isso, é só me dizer o que aconteceu.';
      return const CommentReply(t, 'comment:mood');
    }
    final open = repository.openBills;
    final String state;
    if (open.isEmpty) {
      state = 'Agora você não tem nenhuma conta em aberto aqui. 🙌';
    } else {
      final total = open.fold(0.0, (a, r) => a + (r.amount ?? 0));
      final next = open.first;
      state = 'Você tem ${open.length} ${open.length == 1 ? 'conta' : 'contas'} em aberto${total > 0 ? ' somando ${_m(total)}' : ''}; '
          'a próxima é **${next.title}**, ${CesarText.ddmm(next.targetDate)}.';
    }
    final t = 'Ninguém merece, né? 😅 $state\n\nSe quiser, eu te aviso antes de vencer: diga "me lembra de pagar o boleto de 200 dia 10".';
    return CommentReply(t, 'comment:mood', spoken: 'Ninguém merece. ${state.replaceAll('**', '').replaceAll(' 🙌', '')}');
  }
}
