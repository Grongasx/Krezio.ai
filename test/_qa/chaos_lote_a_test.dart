// Teste do caos — Item 2, lote A do PLANO_CESAR.md (cesar-chaos).
//
// NÃO falha a suíte: só imprime, com o prefixo `CHAOS-A|`.
//   flutter test test/_qa/chaos_lote_a_test.dart 2>&1 | grep "CHAOS-A|"
//   # só violações: ... | grep -E "CHAOS-A\|(ALVO-V|FUZZ\| primeira|MIN|RELOGIO-V|RESUMO)"
//   # mais volume:  A_SEEDS=60 A_LEN=300 flutter test test/_qa/chaos_lote_a_test.dart
//
// Mira o que o lote A mudou: `startsNewTransaction`/`_replacesValuelessDraft`,
// `MoneyDirectionDetector._informalIncoming`, segmentação do `parseMulti` +
// slot `split`, `HypothesisDetector` (ramo em `handleQuestion`),
// `SpokenDayParser` ao LANÇAR, "dia N" × recorrência, `_termScore`.
// Seeds NOVAS: 20261100+n. A regressão das seeds do R3 (20260929+n) é o próprio
// test/_qa/chaos_r3_fuzz_test.dart. Achados em docs/qa/findings-caos-lote-a.md.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_text.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/ai/temporal_date_parser.dart';
import 'package:krezio_ai/ai/category_name_matcher.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chaos_r3_support.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
final DateTime today = _day(DateTime.now());
String ddmmyy(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

/// Um turno com o que o gerador SABE sobre ele (o oráculo).
class LT {
  final String text;
  final String family;
  String? dir; // 'income' | 'expense' — o sinal que a frase tem
  List<double> values = const []; // valores monetários ditos (um por lançamento)
  double? single; // frase de 1 lançamento: o valor certo
  DateTime? expDate; // data que a frase diz (ou hoje quando não diz nenhuma)
  bool mustAsk = false; // data futura / inexistente / mês inteiro: não pode salvar sem perguntar
  bool titleDate = false; // palavra de data só dentro do nome do lugar
  bool? hyp; // true = hipótese; false = fato com "se/caso" que deve ser registrado
  String? named; // nome dito numa edição/exclusão
  bool recurrenceOk = false;
  bool pendingAnswer = false; // resposta a "quanto foi?"
  Map<double, String> valueDir = const {}; // multi misto: direção de cada valor
  LT(this.text, this.family);
  @override
  String toString() => text;
}

class VA {
  final String kind;
  final String detail;
  final int turn;
  VA(this.kind, this.detail, this.turn);
}

// ───────────────────────── fixtures ─────────────────────────

List<FinancialTransaction> fixtures() {
  FinancialTransaction f(String id, String title, double amount, String cat, int daysAgo, {TransactionType type = TransactionType.expense}) =>
      FinancialTransaction(
          id: id, title: title, amount: amount, type: type, category: cat, paymentMethod: 'pix', date: today.subtract(Duration(days: daysAgo)).add(const Duration(hours: 12)));
  return [
    f('fx-feira-sab', 'Feira', 80, 'supermarket', (today.weekday - 6) % 7 == 0 ? 7 : (today.weekday - 6) % 7),
    f('fx-feira-7', 'Feira', 60, 'supermarket', 7),
    f('fx-padaria-sv', 'Padaria Segunda Via', 25, 'supermarket', 1),
    f('fx-pizzaria-sab', 'Pizzaria Sábado', 70, 'food', 5),
    f('fx-bar-dia7', 'Bar Dia 7', 45, 'leisure', 2),
    f('fx-emporio-quinta', 'Empório Quinta', 90, 'supermarket', 6),
    f('fx-posto', 'Posto', 150, 'transport', 1),
    f('fx-uber-2', 'Uber', 30, 'transport', 2),
    f('fx-uber-1', 'Uber', 22, 'transport', 1),
    f('fx-farm', 'Farmácia', 40, 'health', 5),
    f('fx-freela', 'Freela', 300, 'income_other', 4, type: TransactionType.income),
  ];
}

Future<FinancialRepository> freshRepo() async {
  SharedPreferences.setMockInitialValues({});
  final repo = FinancialRepository();
  await repo.initialize();
  for (final t in fixtures()) {
    repo.addTransaction(t);
  }
  repo.addGoal(FinancialGoal(id: 'g-fone', title: 'Fone', targetAmount: 150, savedAmount: 40));
  repo.addGoal(FinancialGoal(id: 'g-viagem', title: 'Viagem', targetAmount: 5000));
  repo.addReminder(FinancialReminder(
      id: 'rem-joao', title: 'João me deve', personName: 'João', amount: 500, targetDate: today.add(const Duration(days: 20)), type: ReminderType.loanReceivable));
  return repo;
}

Map<String, String> remSnap(FinancialRepository r) => {for (final x in r.reminders) x.id: '${x.amount}|${x.isCompleted}'};

// ───────────────────────── oráculo de datas ─────────────────────────

class DateFrag {
  final String text;
  final DateTime? exp;
  final bool ask;
  DateFrag(this.text, this.exp, this.ask);
}

const _wdNames = {1: 'segunda', 2: 'terça', 3: 'quarta', 4: 'quinta', 5: 'sexta', 6: 'sábado', 7: 'domingo'};
int _daysIn(int y, int m) => DateTime(y, m + 1, 0).day;

DateFrag dateFrag(Random rng, DateTime now) {
  final t = _day(now);
  final r = rng.nextInt(100);
  if (r < 10) return DateFrag('ontem', t.subtract(const Duration(days: 1)), false);
  if (r < 16) return DateFrag('anteontem', t.subtract(const Duration(days: 2)), false);
  if (r < 34) {
    final wd = 1 + rng.nextInt(7);
    var back = (t.weekday - wd) % 7;
    if (back == 0) back = 7;
    final name = _wdNames[wd]!;
    final form = rng.nextInt(5);
    if (form == 0 && wd <= 5) return DateFrag('na $name-feira', t.subtract(Duration(days: back)), false);
    if (form == 1) return DateFrag('$name passad${wd >= 6 ? 'o' : 'a'}', t.subtract(Duration(days: back)), false);
    if (form == 2) return DateFrag('${wd >= 6 ? 'no' : 'na'} $name', t.subtract(Duration(days: back)), false);
    return DateFrag(name, t.subtract(Duration(days: back)), false);
  }
  if (r < 58) {
    final n = rng.nextInt(10) == 0 ? pickOf(rng, [0, 32, 45, 99]) : 1 + rng.nextInt(31);
    final form = rng.nextBool() ? 'dia $n' : 'no dia $n';
    if (n < 1 || n > 31) return DateFrag(form, null, true);
    var y = t.year, m = t.month;
    if (n > t.day) {
      m--;
      if (m == 0) {
        m = 12;
        y--;
      }
    }
    if (n > _daysIn(y, m)) return DateFrag(form, null, true);
    return DateFrag(form, DateTime(y, m, n), false);
  }
  if (r < 74) {
    final dd = 1 + rng.nextInt(31), mm = rng.nextInt(12) == 0 ? 13 : 1 + rng.nextInt(12);
    final txt = '${rng.nextBool() ? dd.toString().padLeft(2, '0') : dd}/${mm.toString().padLeft(2, '0')}';
    final form = rng.nextBool() ? 'em $txt' : txt;
    if (mm > 12) return DateFrag(form, null, true);
    final ahead = mm > t.month || (mm == t.month && dd > t.day);
    final y = ahead ? t.year - 1 : t.year;
    if (dd > _daysIn(y, mm)) return DateFrag(form, null, true);
    return DateFrag(form, DateTime(y, mm, dd), false);
  }
  if (r < 82) {
    final n = 1 + rng.nextInt(10);
    return DateFrag(rng.nextBool() ? 'há $n dias' : '$n dias atrás', t.subtract(Duration(days: n)), false);
  }
  if (r < 88) return DateFrag(pickOf(rng, ['amanhã', 'depois de amanhã']), null, true);
  if (r < 92) return DateFrag('mês passado', null, true);
  if (r < 96) return DateFrag('hoje', t, false);
  return DateFrag('domingo retrasado', t.subtract(Duration(days: ((t.weekday - 7) % 7 == 0 ? 7 : (t.weekday - 7) % 7) + 7)), false);
}

T pickOf<T>(Random rng, List<T> l) => l[rng.nextInt(l.length)];

// ───────────────────────── gerador ─────────────────────────

class GenA {
  final Random rng;
  final int length;
  GenA(this.rng, this.length);
  int _n = 0;
  final List<LT> _q = [];

  T pick<T>(List<T> l) => l[rng.nextInt(l.length)];
  static const _amts = [7, 12, 25, 30, 45, 60, 80, 99, 120, 250, 1400];
  int amt() => pick(_amts);
  List<int> distinctAmts(int k) {
    final s = <int>{};
    while (s.length < k) {
      s.add(amt());
    }
    return s.toList();
  }

  static const _places = [' no mercado', ' na padaria', ' no uber', ' na farmácia', ' no posto', ' no ifood', ' no açougue', ' no cinema'];
  // Palavras de data DENTRO do nome do lugar (a frase não diz data nenhuma).
  static const _titlePlaces = [
    ' na Padaria Segunda Via', ' na Pizzaria Sábado', ' no Bar Dia 7', ' no Empório Quinta', ' no Sexta Burger', ' no Hortifruti Domingo',
    ' no totem do estacionamento', ' no projeto da casa', ' na loja nota 10/10', ' no Bar do Dia 20', ' na Quinta da Boa Vista', ' no Terça Nobre',
    ' no Bar Fim de Semana', ' no Totem Lanches', ' na Pizzaria Sábado', ' no Bar Dia 7', ' na Padaria Segunda Via',
  ];
  static const _pays = [' no pix', ' no débito', ' no dinheiro', ' no crédito à vista', ''];

  /// (texto com {A}, direção) — sinais de receita e de despesa, incluindo os
  /// informais do lote A.
  static const _cores = <List<String>>[
    ['gastei {A}{P}', 'expense'],
    ['paguei {A}{P}', 'expense'],
    ['torrei {A}{P}', 'expense'],
    ['comprei um negócio de {A}{P}', 'expense'],
    ['me cobraram {A} de taxa{P}', 'expense'],
    ['o banco me cobrou {A} de tarifa', 'expense'],
    ['recebi a conta de luz de {A}', 'expense'],
    ['recebi o boleto de {A} do condomínio', 'expense'],
    ['debitaram {A} da minha conta{P}', 'expense'],
    ['recebi {A} de freela', 'income'],
    ['ganhei {A} de presente', 'income'],
    ['caiu {A} do freela', 'income'],
    ['o joão me mandou {A}', 'income'],
    ['me pagaram {A} do bico', 'income'],
    ['entrou {A} de salário', 'income'],
    ['vendi a bike por {A}', 'income'],
    ['meu pai me deu {A}', 'income'],
    ['descolei {A} com o vizinho', 'income'],
    ['o chefe pagou {A} do extra', 'income'],
    ['pingou {A} na conta do freela', 'income'],
    ['me devolveram {A}{P}', 'income'],
    ['recebi {A} de volta{P}', 'income'],
    ['a maria me passou {A}', 'income'],
    // "me + verbo" que não é dinheiro entrando (falso positivo de _informalIncoming)
    ['o joão me mandou pagar {A} de luz{P}', 'expense'],
    ['me obrigaram a pagar {A} de multa{P}', 'expense'],
    ['o mecânico me orçou {A} e paguei{P}', 'expense'],
    ['o garçom me passou a conta de {A} e paguei{P}', 'expense'],
    ['o vendedor me empurrou um seguro de {A}{P}', 'expense'],
    ['vendi o sofá por {A}', 'income'],
  ];

  LT next(FinancialRepository repo) {
    _n++;
    if (_q.isNotEmpty) return _q.removeAt(0);
    if (_n > length) return LT('⟲fim', 'fim');
    final r = rng.nextInt(1000);
    if (r < 150) return _valuelessPair();
    if (r < 330) return _launch();
    if (r < 500) return _multi();
    if (r < 640) return _hypothesis();
    if (r < 780) return _editDelete();
    if (r < 830) return _recurrence();
    return _noise();
  }

  /// Frase de lançamento simples com data em qualquer posição (ou nome com
  /// palavra de data).
  LT _launch({bool allowTitle = true}) {
    final core = pick(_cores);
    final a = amt();
    final useTitle = allowTitle && rng.nextInt(4) == 0;
    final place = useTitle ? pick(_titlePlaces) : (rng.nextBool() ? pick(_places) : '');
    var body = core[0].replaceAll('{A}', '$a').replaceAll('{P}', place);
    if (!core[0].contains('{P}') && useTitle) body = '$body$place';
    final pay = pick(_pays);
    DateFrag? d = rng.nextInt(3) == 0 ? null : dateFrag(rng, today);
    String text;
    if (d == null) {
      text = '$body$pay';
    } else {
      final pos = rng.nextInt(3);
      if (pos == 0) {
        text = '${d.text} $body$pay';
      } else if (pos == 1) {
        final i = body.indexOf('$a') + '$a'.length;
        text = '${body.substring(0, i)} ${d.text}${body.substring(i)}$pay';
      } else {
        text = '$body$pay ${d.text}';
      }
    }
    final lt = LT(text, useTitle ? 'lançar-título' : 'lançar')
      ..dir = core[1]
      ..single = a.toDouble();
    if (d == null) {
      lt.expDate = today;
      lt.titleDate = useTitle;
    } else {
      lt.expDate = d.exp;
      lt.mustAsk = d.ask;
    }
    return lt;
  }

  LT _multi() {
    final r = rng.nextInt(100);
    if (r < 55) {
      final k = 2 + rng.nextInt(3);
      final vals = distinctAmts(k);
      final places = ([..._places]..shuffle(rng)).take(k).toList();
      final seps = [' e ', ', ', ' ', ' mais ', '; ', ' e também '];
      final buf = StringBuffer(pick(['gastei ', 'paguei ', 'hoje gastei ', 'torrei ']));
      for (var j = 0; j < k; j++) {
        if (j > 0) buf.write(j == k - 1 ? pick(seps) : pick([', ', ' ', ' e ']));
        buf.write('${vals[j]}${places[j]}');
      }
      buf.write(pick(_pays));
      String text = buf.toString();
      DateTime? exp = today;
      if (rng.nextInt(3) == 0) {
        final d = dateFrag(rng, today);
        text = '$text ${d.text}';
        exp = d.ask ? null : d.exp;
      }
      return LT(text, 'multi-$k')
        ..dir = 'expense'
        ..values = vals.map((e) => e.toDouble()).toList()
        ..expDate = exp;
    }
    final a = distinctAmts(2);
    final templ = pick(<List<Object>>[
      ['recebi ${a[0]} de freela e gastei ${a[1]} no mercado no pix', 'mixed', 2],
      ['paguei ${a[0]} no mercado e ganhei ${a[1]} de cashback no pix', 'mixed', 2],
      ['gastei ${a[0]} no mercado e ${a[0]} na farmácia no pix', 'expense', 2],
      ['gastei ${a[0]} no mercado ${a[0]} na farmácia no pix', 'expense', 2],
      ['almoço ${a[0]} janta ${a[1]} no pix', 'expense', 2],
      ['paguei ${a[0]} de luz ${a[1]} de água no boleto', 'expense', 2],
      ['gastei ${a[0]} no mercado e o uber deu ${a[1]} no pix', 'expense', 2],
      ['gastei ${a[0]} no mercado com 3 pessoas no pix', 'expense', 1],
      ['paguei ${a[0]} de uber pra 2 pessoas no pix', 'expense', 1],
      ['gastei ${a[0]} no mercado do apartamento 302 no pix', 'expense', 1],
      ['paguei a parcela 3/10 de ${a[0]} no pix', 'expense', 1],
      ['paguei a parcela 2 de 12 da tv, ${a[0]} no pix', 'expense', 1],
      ['comprei 2 kg de carne por ${a[0]} no pix', 'expense', 1],
      ['gastei ${a[0]} na loja 24 horas no pix', 'expense', 1],
      ['gastei ${a[0]} no mercado e o troco foi ${a[1]} no dinheiro', 'expense', 1],
      ['abasteci ${a[0]} de gasolina, 40 litros, no débito', 'expense', 1],
      ['comprei 1/2 kg de queijo por ${a[0]} no pix', 'expense', 1],
      ['gastei ${a[0]} no uber ${a[0]} no ifood no pix', 'expense', 2],
      ['café ${a[0]} pão ${a[1]} no pix', 'expense', 2],
      ['uber ${a[0]} uber ${a[1]} no pix', 'expense', 2],
      ['paguei ${a[0]} de luz, ${a[0]} de água no boleto', 'expense', 2],
      ['recebi ${a[0]} do joão ${a[1]} da maria no pix', 'income', 2],
      ['gastei ${a[0]} no Bar Dia 7 e ${a[1]} na farmácia no pix', 'expense', 2],
      ['gastei ${a[0]} na Pizzaria Sábado e ${a[1]} no uber no pix', 'expense', 2],
    ]);
    final text = templ[0] as String;
    final n = templ[2] as int;
    final lt = LT(text, n == 1 ? 'numeros-nao-valor' : 'multi-2')..expDate = today;
    if (templ[1] != 'mixed') lt.dir = templ[1] as String;
    if (text.startsWith('recebi ${a[0]} de freela e gastei')) lt.valueDir = {a[0].toDouble(): 'income', a[1].toDouble(): 'expense'};
    if (text.startsWith('paguei ${a[0]} no mercado e ganhei')) lt.valueDir = {a[0].toDouble(): 'expense', a[1].toDouble(): 'income'};
    if (n == 1) {
      lt.single = a[0].toDouble();
    } else {
      lt.values = text.contains('${a[1]}') ? [a[0].toDouble(), a[1].toDouble()] : [a[0].toDouble(), a[0].toDouble()];
    }
    return lt;
  }

  LT _hypothesis() {
    final a = amt();
    final r = rng.nextInt(100);
    if (r < 60) {
      final t = pick([
        'se eu gastar $a no mercado quanto sobra?',
        'e se eu comprar um celular de $a em 10x?',
        'caso eu pague $a de luz, fico no vermelho?',
        'quanto fica $a em 6x?',
        'vale a pena comprar um tênis de $a?',
        'se eu guardar $a na meta do fone, quanto falta?',
        'se eu guardar $a na meta do fone',
        'se o joão me pagar $a, quanto ele fica devendo?',
        'se o joão me pagar $a',
        'se a gente gastar $a no jantar no pix',
        'comprar um notebook de $a se sobrar dinheiro',
        '$a no mercado, se eu for amanhã',
        'gastaria $a no mercado se tivesse desconto',
        'se eu tivesse gastado $a ontem no mercado',
        'caso sobre $a no fim do mês, guardo na meta da viagem',
        'e se fosse $a no pix?',
        'se eu transferir $a pra minha mãe no pix',
        'caso eu receba $a de freela',
        'no mês que vem, se eu gastar $a no mercado no pix, estoura?',
        'quero comprar um tênis de $a no pix se tiver desconto',
        'SE EU GASTAR $a NO MERCADO',
        'se eu receber $a de freela e gastar ${a + 10} no mercado',
        'pensando aqui: se eu parcelar $a em 5x no crédito',
        'caso a gente pague $a no jantar no pix',
        'supondo que eu gaste $a no mercado no pix',
        'digamos que eu pague $a de luz no pix',
        'quero gastar $a no mercado no pix se der',
        'vou comprar um tênis de $a no pix se sobrar',
        'compro um celular de $a no pix se o salário cair',
        'e se o mercado der $a?',
        'na hipótese de eu gastar $a no mercado no pix',
      ]);
      // A hipótese que não foi reconhecida vira rascunho; as respostas
      // seguintes não podem completá-lo e salvar.
      if (rng.nextInt(3) == 0) {
        _q.add(LT(pick(['no pix', 'no débito', 'mercado', 'sim']), 'hipótese-cont')..hyp = true);
        if (rng.nextBool()) _q.add(LT(pick(['mercado', 'no pix', 'farmácia']), 'hipótese-cont')..hyp = true);
      }
      return LT(t, 'hipótese')..hyp = true;
    }
    final t = pick(<List<Object>>[
      ['gastei $a no mercado, se não me engano, no pix', 'expense'],
      ['se não me falha a memória gastei $a na padaria no pix', 'expense'],
      ['no caso eu gastei $a no mercado no pix', 'expense'],
      ['paguei $a pro advogado do caso trabalhista no pix', 'expense'],
      ['gastei $a no mercado no pix, se esse valor tiver errado te aviso', 'expense'],
      ['gastei $a no mercado no pix, se precisar mando o comprovante', 'expense'],
      ['comprei um tênis de $a no pix, se fosse no crédito saía mais caro', 'expense'],
      ['paguei $a de uber no pix pra ela se sentir segura', 'expense'],
      ['gastei $a no mercado no pix e se sobrar eu guardo', 'expense'],
      ['recebi $a de freela no pix caso você queira saber', 'income'],
      ['paguei $a no pix num caso de emergência', 'expense'],
      ['gastei $a na farmácia no pix, se eu lembro bem', 'expense'],
      ['paguei $a no conserto do pneu que se furou no pix', 'expense'],
      ['gastei $a com o caso da geladeira no pix', 'expense'],
      ['gastei $a no mercado no pix, se quiser te mando a nota', 'expense'],
      ['paguei $a no conserto no pix, se quebrar de novo tem garantia', 'expense'],
      ['recebi $a de freela no pix, se eu tiver mais trabalho te aviso', 'income'],
      ['paguei $a no bar no pix; se for preciso divido depois', 'expense'],
      ['gastei $a na farmácia no pix. se eu melhorar volto pra academia', 'expense'],
      ['gastei $a no mercado no pix, se por acaso perguntarem', 'expense'],
      ['paguei $a do caso do seguro no pix', 'expense'],
      ['gastei $a em caso de emergência no pix', 'expense'],
    ]);
    return LT(t[0] as String, 'fato-com-se')
      ..hyp = false
      ..dir = t[1] as String
      ..single = a.toDouble()
      ..expDate = today;
  }

  LT _valuelessPair() {
    final p = pick(<List<String?>>[
      ['gastei no mercado no pix', 'expense'],
      ['paguei o aluguel', 'expense'],
      ['comprei um tênis', 'expense'],
      ['recebi meu salário', 'income'],
      ['a feira hoje tava ótima', null],
      ['paguei a pizzaria sábado', 'expense'],
      ['gastei no bar dia 7 no pix', 'expense'],
      ['caiu o pix do freela', 'income'],
      ['o joão me mandou um pix', 'income'],
      ['gastei na padaria segunda via', 'expense'],
      ['paguei o uber de segunda', 'expense'],
    ]);
    final pend = LT(p[0]!, 'rascunho')..dir = p[1];
    final r = rng.nextInt(100);
    LT follow;
    if (r < 40) {
      final a = amt();
      final f = pick(<List<Object?>>[
        ['$a', null],
        ['foi $a', null],
        ['uns $a reais', null],
        ['$a no pix', null],
        ['deu $a', null],
        ['R\$ $a', null],
        ['$a conto', null],
        ['foi $a ontem', -1],
        ['foi $a no débito', null],
        ['foi $a anteontem', -2],
        ['$a e ${a + 10}', 'two'],
        ['uns $a ou ${a + 10}', 'two'],
      ]);
      follow = LT(f[0] as String, 'resposta')
        ..pendingAnswer = true
        ..dir = p[1]
        ..single = a.toDouble();
      if (f[1] == 'two') {
        follow
          ..pendingAnswer = false
          ..single = null
          ..values = [a.toDouble(), a + 10.0];
      } else if (f[1] != null) {
        follow.expDate = today.add(Duration(days: f[1] as int));
      }
    } else if (r < 80) {
      follow = rng.nextBool() ? _launch() : _multi();
    } else {
      follow = rng.nextBool()
          ? _hypothesis()
          : LT(pick(['sim', 'não sei', 'cancela', 'quanto gastei ontem?', 'o uber foi 30', 'e se eu pagar no pix?', '50 ou 60', 'entre 40 e 50', '2 de 30']), 'rascunho-outro');
      if (follow.text == 'o uber foi 30') {
        follow
          ..dir = 'expense'
          ..single = 30
          ..expDate = today;
      }
      if (follow.text == 'e se eu pagar no pix?') follow.hyp = true;
      if (follow.text == '50 ou 60') follow.values = const [50, 60];
      if (follow.text == 'entre 40 e 50') follow.values = const [40, 50];
    }
    _q.add(follow);
    return pend;
  }

  LT _editDelete() {
    final a = amt();
    final t = pick(<List<String>>[
      ['muda a pizzaria sábado pra $a', 'pizzaria'],
      ['a pizzaria de sábado foi $a', 'pizzaria'],
      ['muda o bar dia 7 pra $a', 'bar'],
      ['muda o bar do dia 7 pra $a', 'bar'],
      ['muda a padaria segunda via pra $a', 'padaria'],
      ['a padaria de segunda foi $a', 'padaria'],
      ['muda a feira de segunda pra $a', 'feira'],
      ['muda a feira de ontem pra $a', 'feira'],
      ['muda o empório de quinta pra $a', 'emporio'],
      ['muda o mercado de quinta pra $a', 'mercado'],
      ['muda o açougue pra $a', 'acougue'],
      ['muda o cinema de ontem pra $a', 'cinema'],
      ['muda a gasolina de segunda pra $a', 'gasolina'],
      ['o uber de domingo foi $a', 'uber'],
      ['muda o sexta burger pra $a', 'sexta burger'],
      ['apaga a pizzaria sábado', 'pizzaria'],
      ['apaga o bar do dia 7', 'bar'],
      ['apaga a padaria de segunda', 'padaria'],
      ['apaga a feira de segunda', 'feira'],
      ['apaga o empório quinta', 'emporio'],
      ['apaga o açougue de ontem', 'acougue'],
      ['apaga o mercado de quinta', 'mercado'],
      ['exclui o cinema', 'cinema'],
      ['apaga a feira do dia 7', 'feira'],
      ['muda o cinema de segunda pra $a', 'cinema'],
      ['apaga o cinema de segunda', 'cinema'],
      ['muda o táxi de segunda pra $a', 'taxi'],
      ['muda o posto de segunda pra $a', 'posto'],
      ['muda a lanchonete de sexta pra $a', 'lanchonete'],
      ['muda a data da pizzaria pra dia 7', 'pizzaria'],
    ]);
    final lt = LT(t[0], 'editar-apagar')..named = t[1];
    if (t[0].startsWith('apaga') || t[0].startsWith('exclui')) {
      if (rng.nextInt(4) > 0) _q.add(LT(pick(['sim', 'sim', 'pode apagar', '1', 'não']), 'confirma')..named = t[1]);
    } else if (rng.nextInt(3) == 0) {
      _q.add(LT(pick(['sim', '1', 'não']), 'confirma')..named = t[1]);
    }
    return lt;
  }

  LT _recurrence() {
    final a = amt();
    final n = 1 + rng.nextInt(28);
    final t = pick(<List<Object>>[
      ['todo dia $n pago $a de academia no débito', true],
      ['pago $a de academia dia $n no débito', true],
      ['assinei a netflix por $a no crédito', true],
      ['minha internet de $a vence dia $n no boleto', true],
      ['paguei a academia dia $n, $a no débito', false],
      ['gastei $a no mercado dia $n no pix', false],
      ['paguei o aluguel de $a dia $n no pix', false],
      ['recebi $a de salário dia $n no pix', false],
      ['paguei $a de internet no pix', false],
      ['gastei $a na netflix no pix', false],
      ['paguei $a da mensalidade da escola no pix', true],
    ]);
    return LT(t[0] as String, 'recorrência')..recurrenceOk = t[1] as bool;
  }

  LT _noise() => LT(
      pick([
        'desfaz', 'cancela', 'sim', 'não', 'quanto gastei ontem?', 'qual meu saldo?', 'quais foram meus últimos lançamentos?', '1', 'pix', 'esquece',
        'quanto gastei na pizzaria?', 'e anteontem?', '', '💸', 'dia 7', 'segunda', '10/10', 'se', 'caso', 'se eu', 'caso sim',
      ]),
      'ruído');
}

// ───────────────────────── execução + invariantes ─────────────────────────

const _recWords =
    r'\b(?:todo|toda|todos|todas|mensal|mensalmente|mensalidade|assinatura|assinei|assino|vence|vencimento|cai|sempre|por mes|ao mes|semanal|semanalmente|anual|fixo|fixa|recorrente|pago|recebo|ganho|plano)\b';
const _catRecWords = r'\b(?:aluguel|salario|netflix|spotify|academia|condominio|internet|escola)\b';

final routeCount = <String, int>{};
final statCount = <String, int>{};
void stat(String k) => statCount[k] = (statCount[k] ?? 0) + 1;

class RunA {
  final List<VA> v;
  final List<LT> sent;
  RunA(this.v, this.sent);
}

Future<RunA> runA(LocalFinancialNlpEngine engine, {List<LT>? fixed, GenA? gen, bool verbose = false}) async {
  final repo = await freshRepo();
  final sim = Sim3(engine, repo);
  final v = <VA>[];
  final sent = <LT>[];
  String? prevRoute;
  var prevText = '';

  for (var i = 0; i < (fixed?.length ?? 100000); i++) {
    final lt = fixed != null ? fixed[i] : gen!.next(repo);
    if (lt.text == '⟲fim') break;
    sent.add(lt);
    final before = Snap3.of(repo);
    final remB = remSnap(repo);
    R3Reply r;
    try {
      r = sim.send(lt.text);
    } catch (e, st) {
      v.add(VA('excecao', '"${lt.text}" → $e ${st.toString().split('\n').take(2).join(' | ')}', i));
      break;
    }
    final after = Snap3.of(repo);
    final remA = remSnap(repo);
    routeCount[r.route] = (routeCount[r.route] ?? 0) + 1;
    final reply = r.text.replaceAll('\n', ' ');
    final shortReply = reply.length > 160 ? '${reply.substring(0, 160)}…' : reply;
    void viol(String kind, String detail) => v.add(VA(kind, '"${lt.text}" → [${r.route}] $detail', i));
    if (verbose) print('CHAOS-A|TRACE| ${i + 1}. "${lt.text}" → ${r.short}');

    if (r.text.trim().isEmpty) viol('resposta_vazia', '');
    for (final p in repoInvariants(repo)) {
      viol(p.split(':').first, p);
    }
    final s = CesarText.simplify(lt.text);
    final added = after.tx.keys.where((k) => !before.tx.containsKey(k)).map((k) => jsonDecode(after.tx[k]!) as Map).toList();
    final removed = before.tx.keys.where((k) => !after.tx.containsKey(k)).toList();
    final changed = before.tx.keys.where((k) => after.tx.containsKey(k) && after.tx[k] != before.tx[k]).toList();
    final isUndo = r.route == 'undo';

    // ── nada some sem "sim" / nada muda sem comando (herdados do R3) ──
    final confirmedDelete = prevRoute == 'confirm_delete' && yesRe.hasMatch(s);
    if (removed.isNotEmpty && !((r.route == 'deleted' && confirmedDelete) || isUndo || r.route == 'correction_cancel')) {
      viol('apagou_sem_sim', 'removeu ${removed.map((k) => describeTx(before.tx[k]!)).take(3).toList()}');
    }
    if (changed.isNotEmpty && !const {'edited', 'undo', 'correction'}.contains(r.route)) {
      viol('mudou_sem_comando', 'mudou ${changed.map((k) => '${describeTx(before.tx[k]!)} ⇒ ${describeTx(after.tx[k]!)}').take(2).toList()}');
    }

    // ── nenhuma hipótese salva ──
    if (lt.hyp == true) {
      final goalsChanged = !before.sameData(after) || before.goals.toString() != after.goals.toString();
      if (added.isNotEmpty || changed.isNotEmpty || removed.isNotEmpty || goalsChanged || remA.toString() != remB.toString()) {
        viol('hipotese_salva',
            'hipótese mudou dados: +${added.map((m) => '${m['title']} ${m['amount']} ${m['type']}').toList()} Δmetas=${before.goals.toString() != after.goals.toString()} Δdívidas=${remA.toString() != remB.toString()} :: $shortReply');
      }
    }
    if (lt.hyp == false && r.route == 'hypothesis') viol('fato_virou_hipotese', shortReply);

    // ── lançamentos novos ──
    if (!isUndo && added.isNotEmpty) {
      final plural = added.length > 1;
      for (final m in added) {
        final date = _day(DateTime.parse(m['date'] as String));
        final typ = m['type'] as String;
        final amount = (m['amount'] as num).toDouble();
        final rec = m['isRecurrent'] == true;
        final desc = '${m['title']} ${CesarText.money(amount)} $typ em ${ddmmyy(date)}${rec ? ' RECORRENTE dueDay=${m['dueDay']}' : ''}';
        if (!rec && date.isAfter(today)) viol('data_futura', 'salvou $desc');
        if (lt.mustAsk && !rec) viol('data_nao_perguntada', 'salvou $desc (a data dita é futura/inexistente/mês inteiro)');
        if (lt.expDate != null && !rec && date != lt.expDate) {
          viol(lt.titleDate ? 'data_do_titulo' : (plural ? 'data_errada_multi' : 'data_errada'), 'salvou $desc, esperado ${ddmmyy(lt.expDate!)}');
        }
        if (rec && !RegExp(_recWords).hasMatch(s) && !lt.recurrenceOk) {
          viol(RegExp(_catRecWords).hasMatch(s) ? 'recorrente_por_categoria' : 'recorrente_sem_palavra', 'salvou $desc');
        }
        if (lt.dir != null && !plural && typ != 'transfer' && typ != lt.dir) viol('tipo_trocado', 'frase com sinal de ${lt.dir}, salvou $desc');
        if (lt.single != null && !plural && (amount - lt.single!).abs() > 0.005 && !lt.pendingAnswer) {
          viol('valor_trocado', 'esperado ${CesarText.money(lt.single!)}, salvou $desc');
        }
        if (lt.pendingAnswer && lt.single != null && (amount - lt.single!).abs() > 0.005) viol('valor_trocado', 'resposta ${lt.single}, salvou $desc');
      }
      // ── 2+ valores monetários nunca viram 1 lançamento em silêncio ──
      if (lt.values.length >= 2 && added.length < lt.values.length) {
        final amounts = added.map((m) => (m['amount'] as num).toDouble()).toList();
        final missing = [...lt.values];
        for (final a in amounts) {
          final j = missing.indexWhere((x) => (x - a).abs() < 0.005);
          if (j >= 0) missing.removeAt(j);
        }
        final kind = added.length == 1 ? 'multi_valor_um_lancamento' : 'multi_valor_parcial';
        viol(kind,
            '${lt.values.length} valores ${lt.values.map(CesarText.money).toList()} → ${added.length} lançamento(s) ${added.map((m) => '${m['title']} ${m['amount']}').toList()}; perdeu ${missing.map(CesarText.money).toList()}');
      }
      for (final m in added) {
        final want = lt.valueDir[(m['amount'] as num).toDouble()];
        if (want != null && m['type'] != want && m['type'] != 'transfer') {
          viol('tipo_trocado_multi', 'valor ${m['amount']} devia ser $want, salvou ${m['title']} ${m['type']}');
        }
      }
      if (lt.values.length >= 2) {
        final sum = lt.values.fold(0.0, (a, b) => a + b);
        for (final m in added) {
          final amount = (m['amount'] as num).toDouble();
          if (!lt.values.any((x) => (x - amount).abs() < 0.005)) viol((amount - sum).abs() < 0.005 ? 'multi_somado' : 'multi_valor_inventado', 'salvou ${m['title']} $amount de ${lt.values}');
        }
      }
    }
    if (lt.pendingAnswer && reply.contains('Deixei de lado')) viol('resposta_nao_fundida', 'resposta a "quanto foi?" abriu outro lançamento: $shortReply');
    if (lt.values.length >= 2 && added.isEmpty) stat('multi_perguntou_ou_recusou');
    if (lt.mustAsk && added.isEmpty) stat('data_perguntada');

    // ── edição/exclusão só atinge registro cujo título contém o nome dito ──
    if (lt.named != null && !isUndo) {
      final nm = CesarText.fold(lt.named!);
      bool hasName(String json) => CesarText.fold((jsonDecode(json) as Map)['title'] as String).contains(nm);
      if (r.route == 'edited') {
        for (final k in changed) {
          if (!hasName(before.tx[k]!)) {
            final cat = (jsonDecode(before.tx[k]!) as Map)['category'];
            viol(CesarText.categoryWords[nm] == cat ? 'editou_por_categoria' : 'editou_sem_nome',
                'mudou ${describeTx(before.tx[k]!)} ⇒ ${describeTx(after.tx[k]!)} sem confirmação (nome dito "${lt.named}") :: $shortReply');
          }
        }
      }
      if (r.route == 'deleted') {
        for (final k in removed) {
          final title = (jsonDecode(before.tx[k]!) as Map)['title'] as String;
          if (!hasName(before.tx[k]!)) {
            if (prevText.contains(title)) {
              stat('apagou_outro_nome_com_confirmacao');
              viol('confirmou_outro_nome', 'apagou "$title" (nome dito "${lt.named}"); a confirmação mostrava o item: "${prevText.replaceAll('\n', ' ')}"');
            } else {
              viol('apagou_outro', 'apagou "$title", que não estava na confirmação "${prevText.replaceAll('\n', ' ')}"');
            }
          }
        }
      }
      if (r.route == 'confirm_delete' || r.route == 'choose' || r.route == 'ask_target') {
        stat('confirmacao_${r.route}');
      }
    }
    prevRoute = r.route;
    prevText = r.text;

  }

  return RunA(v, sent);
}

Future<List<LT>> minimizeA(LocalFinancialNlpEngine engine, List<LT> turns, String kind, Stopwatch sw, int deadlineMs) async {
  Future<bool> fails(List<LT> ts) async => (await runA(engine, fixed: ts)).v.any((x) => x.kind == kind);
  var cur = List<LT>.from(turns);
  final first = (await runA(engine, fixed: cur)).v.where((x) => x.kind == kind).toList();
  if (first.isEmpty) return cur;
  cur = cur.sublist(0, first.first.turn + 1);
  // Tenta a última frase sozinha e com a anterior.
  for (final cand in [
    [cur.last],
    if (cur.length >= 2) cur.sublist(cur.length - 2),
    if (cur.length >= 3) cur.sublist(cur.length - 3),
  ]) {
    if (await fails(cand)) return cand;
  }
  var chunk = max(1, cur.length ~/ 2);
  while (chunk >= 1) {
    var i = 0;
    var progressed = false;
    while (i < cur.length) {
      if (sw.elapsedMilliseconds > deadlineMs) return cur;
      final end = min(cur.length, i + chunk);
      final cand = [...cur.sublist(0, i), ...cur.sublist(end)];
      if (cand.isNotEmpty && await fails(cand)) {
        cur = cand;
        progressed = true;
      } else {
        i += chunk;
      }
    }
    if (!progressed) chunk ~/= 2;
  }
  return cur;
}

// ───────────────────────── casos-alvo determinísticos ─────────────────────────

LT L(String t, {String? dir, double? single, List<double> values = const [], DateTime? exp, bool ask = false, bool? hyp, String? named, bool title = false, bool answer = false}) =>
    LT(t, 'alvo')
      ..dir = dir
      ..single = single
      ..values = values
      ..expDate = exp
      ..mustAsk = ask
      ..hyp = hyp
      ..named = named
      ..titleDate = title
      ..pendingAnswer = answer;

/// "dia N" como o motor deve ler ao lançar: o dia N mais recente que já passou (este mês ou o anterior).
DateTime? diaN(int n, [DateTime? now]) {
  final t = _day(now ?? today);
  var y = t.year, m = t.month;
  if (n > t.day) {
    m--;
    if (m == 0) {
      m = 12;
      y--;
    }
  }
  return (n < 1 || n > _daysIn(y, m)) ? null : DateTime(y, m, n);
}

/// Última ocorrência (1–7 dias atrás) do dia da semana [wd].
DateTime wdLast(int wd, [DateTime? now]) {
  final t = _day(now ?? today);
  var b = (t.weekday - wd) % 7;
  if (b == 0) b = 7;
  return DateTime(t.year, t.month, t.day - b);
}

/// "dd/mm": este ano se já passou, senão o ano passado.
DateTime? ddmm(int d, int m, [DateTime? now]) {
  final t = _day(now ?? today);
  if (m < 1 || m > 12) return null;
  final ahead = m > t.month || (m == t.month && d > t.day);
  final y = ahead ? t.year - 1 : t.year;
  return (d < 1 || d > _daysIn(y, m)) ? null : DateTime(y, m, d);
}

List<List<LT>> targeted() {
  final t = today;
  DateTime back(int n) => t.subtract(Duration(days: n));
  return [
    // datas dentro de títulos (a frase não diz data)
    [L('gastei 50 na Pizzaria Sábado no pix', dir: 'expense', single: 50, exp: t, title: true)],
    [L('gastei 50 no Bar Dia 7 no pix', dir: 'expense', single: 50, exp: t, title: true)],
    [L('gastei 50 na Padaria Segunda Via no pix', dir: 'expense', single: 50, exp: t, title: true)],
    [L('gastei 50 no Empório Quinta no pix', dir: 'expense', single: 50, exp: t, title: true)],
    [L('gastei 50 no Sexta Burger no pix', dir: 'expense', single: 50, exp: t, title: true)],
    [L('gastei 50 na Quinta da Boa Vista no pix', dir: 'expense', single: 50, exp: t, title: true)],
    [L('paguei 12 no totem do estacionamento no pix', dir: 'expense', single: 12, exp: t, title: true)],
    [L('gastei 40 na loja nota 10/10 no pix', dir: 'expense', single: 40, exp: t, title: true)],
    [L('comprei 1/2 kg de queijo por 30 no pix', dir: 'expense', single: 30, exp: t, title: true)],
    [L('paguei a parcela 3/10 de 120 no pix', dir: 'expense', single: 120, exp: t, title: true)],
    [L('paguei 300 do projeto sábado no pix', dir: 'expense', single: 300, exp: wdLast(6))],
    [L('gastei 80 no objeto de decoração ontem no pix', dir: 'expense', single: 80, exp: back(1))],
    // datas reais ao lançar
    [L('gastei 50 no mercado dia 30 no pix', dir: 'expense', single: 50, exp: diaN(30))],
    [L('gastei 50 no mercado dia 31 no pix', dir: 'expense', single: 50, exp: diaN(31), ask: diaN(31) == null)],
    [L('gastei 50 no mercado dia 123 no pix', dir: 'expense', single: 50, ask: true)],
    [L('dia 5 gastei 50 no mercado no pix', dir: 'expense', single: 50, exp: diaN(5))],
    [L('gastei no dia 5 50 no mercado no pix', dir: 'expense', single: 50, exp: diaN(5))],
    [L('gastei 50 no mercado na terça no pix', dir: 'expense', single: 50, exp: wdLast(2))],
    [L('gastei 50 no mercado em 30/09 no pix', dir: 'expense', single: 50, exp: ddmm(30, 9))],
    [L('gastei 50 no mercado em 29/02 no pix', dir: 'expense', single: 50, ask: true)],
    [L('gastei 50 no mercado na segunda passada no pix', dir: 'expense', single: 50, exp: wdLast(1))],
    [L('gastei 50 no mercado no fim de semana no pix', dir: 'expense', single: 50)],
    [L('gastei 50 no mercado semana passada no pix', dir: 'expense', single: 50)],
    // "dia N" × recorrência
    [L('paguei a academia dia 5, 90 no débito', dir: 'expense', single: 90, exp: diaN(5))],
    [L('paguei o aluguel de 1500 dia 5 no pix', dir: 'expense', single: 1500, exp: diaN(5))],
    [L('recebi 4500 de salário dia 5 no pix', dir: 'income', single: 4500, exp: diaN(5))],
    [L('paguei 99 de internet no pix', dir: 'expense', single: 99, exp: t)],
    // 2+ números
    [L('gastei 50 no mercado 50 na farmácia no pix', dir: 'expense', values: [50, 50])],
    [L('gastei 50 no mercado e 50 na farmácia no pix', dir: 'expense', values: [50, 50])],
    [L('gastei 50 no mercado 30 na farmácia 20 no uber no pix', dir: 'expense', values: [50, 30, 20])],
    [L('gastei 50 no mercado, 30 na farmácia e 20 no uber e 10 na padaria no pix', dir: 'expense', values: [50, 30, 20, 10])],
    [L('almoço 32 janta 48 no pix', dir: 'expense', values: [32, 48])],
    [L('paguei 150 de luz 90 de água no boleto', dir: 'expense', values: [150, 90])],
    [L('recebi 300 de freela e gastei 50 no mercado no pix', values: [300, 50])..valueDir = {300: 'income', 50: 'expense'}],
    [L('paguei 80 no mercado e ganhei 20 de cashback no pix', values: [80, 20])..valueDir = {80: 'expense', 20: 'income'}],
    [L('gastei cinquenta no mercado e trinta na farmácia no pix', dir: 'expense', values: [50, 30])],
    [L('gastei 50 no mercado mais 30 de gorjeta no pix', dir: 'expense', values: [50, 30])],
    [L('gastei 50 no mercado com 3 pessoas no pix', dir: 'expense', single: 50, exp: t)],
    [L('gastei 45 no bar do km 5 no pix', dir: 'expense', single: 45, exp: t)],
    [L('abasteci 200 de gasolina, 40 litros, no débito', dir: 'expense', single: 200, exp: t)],
    [L('gastei 50 no mercado e o troco foi 10 no dinheiro', dir: 'expense', single: 50, exp: t)],
    [L('paguei a parcela 2 de 12 da tv, 150 no pix', dir: 'expense', single: 150, exp: t)],
    // hipóteses / fatos com "se"
    [L('se eu guardar 100 na meta do fone', hyp: true)],
    [L('se o joão me pagar 200', hyp: true)],
    [L('se o joão me pagar 200, quanto ele fica devendo?', hyp: true)],
    [L('caso sobre 300 no fim do mês, guardo na meta da viagem', hyp: true)],
    [L('comprar um notebook de 3000 se sobrar dinheiro', hyp: true)],
    [L('gastaria 50 no mercado se tivesse desconto', hyp: true)],
    [L('se eu tivesse gastado 50 ontem no mercado', hyp: true)],
    [L('SE EU GASTAR 50 NO MERCADO', hyp: true)],
    [L('pensando aqui: se eu parcelar 1200 em 5x no crédito', hyp: true)],
    [L('se a gente gastar 200 no jantar no pix', hyp: true)],
    [L('quero comprar um tênis de 300 no pix se tiver desconto', hyp: true)],
    [L('50 no mercado, se eu for amanhã', hyp: true)],
    [L('gastei 50 no mercado no pix, se esse valor tiver errado te aviso', dir: 'expense', single: 50, hyp: false)],
    [L('gastei 50 no mercado no pix, se precisar mando o comprovante', dir: 'expense', single: 50, hyp: false)],
    [L('paguei 800 pro advogado do caso trabalhista no pix', dir: 'expense', single: 800, hyp: false)],
    [L('comprei um tênis de 200 no pix, se fosse no crédito saía mais caro', dir: 'expense', single: 200, hyp: false)],
    [L('paguei 60 de uber no pix pra ela se sentir segura', dir: 'expense', single: 60, hyp: false)],
    [L('paguei 150 no pix num caso de emergência', dir: 'expense', single: 150, hyp: false)],
    [L('gastei 90 com o caso da geladeira no pix', dir: 'expense', single: 90, hyp: false)],
    [L('gastei 50 no mercado no pix e se sobrar eu guardo', dir: 'expense', single: 50, hyp: false)],
    // hipótese com rascunho/lote pendente
    [L('gastei 50 no mercado'), L('e se eu pagar no pix?', hyp: true)],
    [L('gastei 50 na feira e 30 na padaria'), L('se for no pix quanto fica?', hyp: true)],
    [L('gastei 50 na feira e 30 na padaria'), L('e se fosse no pix?', hyp: true)],
    [L('gastei no mercado no pix'), L('se for 50', hyp: true)],
    // rascunho sem valor + frase seguinte
    [L('gastei no mercado no pix'), L('50 ou 60', values: [50, 60])],
    [L('gastei no mercado no pix'), L('entre 40 e 50', values: [40, 50])],
    [L('gastei no mercado no pix'), L('foi 50 ontem', dir: 'expense', single: 50, exp: back(1), answer: true)],
    [L('gastei no mercado no pix'), L('o joão me mandou 200', dir: 'income', single: 200)],
    [L('gastei no mercado no pix'), L('me devolveram 30', dir: 'income', single: 30)],
    [L('gastei no mercado no pix'), L('me cobraram 30 de taxa', dir: 'expense', single: 30)],
    [L('recebi meu salário'), L('o banco me cobrou 12 de tarifa', dir: 'expense', single: 12)],
    [L('recebi meu salário'), L('4500 no pix', dir: 'income', single: 4500, answer: true)],
    [L('recebi meu salário'), L('paguei 1500 de aluguel no pix', dir: 'expense', single: 1500)],
    [L('o joão me mandou um pix'), L('200', dir: 'income', single: 200, answer: true)],
    [L('caiu o pix do freela'), L('gastei 50 no mercado no pix', dir: 'expense', single: 50)],
    [L('paguei a pizzaria sábado'), L('70 no pix', dir: 'expense', single: 70, answer: true)],
    [L('gastei no bar dia 7 no pix'), L('45', dir: 'expense', single: 45, answer: true)],
    [L('gastei no mercado no pix'), L('gastei 30 na farmácia no pix', dir: 'expense', single: 30)],
    [L('gastei no mercado no pix'), L('50 no mercado e 30 na farmácia', values: [50, 30])],
    // informal incoming × cobranças
    [L('o joão me mandou 200 no pix', dir: 'income', single: 200)],
    [L('a maria me passou 150 no pix', dir: 'income', single: 150)],
    [L('me pagaram 80 do bico no pix', dir: 'income', single: 80)],
    [L('me cobraram 30 de taxa no pix', dir: 'expense', single: 30)],
    [L('o mecânico me cobrou 300 no pix', dir: 'expense', single: 300)],
    [L('me descontaram 50 do salário', dir: 'expense', single: 50)],
    [L('me mandaram um boleto de 200', dir: 'expense', single: 200)],
    [L('o joão me mandou pagar 50 de luz no pix', dir: 'expense', single: 50)],
    [L('me deu vontade e gastei 80 no shopping no pix', dir: 'expense', single: 80)],
    [L('o uber me deixou em casa, 30 no pix', dir: 'expense', single: 30)],
    [L('meu chefe me pediu 100 emprestado e mandei no pix', dir: 'expense', single: 100)],
    // cadeias: a hipótese/o título não detectado vira rascunho, e a resposta salva
    [L('se o joão me pagar 200', hyp: true), L('no pix', hyp: true)],
    [L('gastaria 50 no mercado se tivesse desconto', hyp: true), L('no pix', hyp: true)],
    [L('caso eu compre um celular de 2000 em 10x', hyp: true)],
    [L('e se eu comprasse um tênis de 300?', hyp: true)],
    [L('me mandaram um boleto de 200', dir: 'expense', single: 200), L('no pix', dir: 'expense', single: 200)],
    [L('gastei 40 na loja nota 10/10 no pix'), L('loja', single: 40, exp: t, title: true)],
    [L('paguei a parcela 3/10 de 120 no pix'), L('tv', single: 120, exp: t, title: true)],
    [L('comprei 1/2 kg de queijo por 30 no pix'), L('mercado', single: 30, exp: t, title: true)],
    [L('paguei 300 do projeto sábado no pix'), L('reforma', single: 300, exp: wdLast(6))],
    [L('gastei no mercado no pix'), L('foi 99', dir: 'expense', single: 99, answer: true)],
    [L('gastei no mercado no pix'), L('99', dir: 'expense', single: 99, answer: true)],
    [L('vendi a bike por 60 no crédito', dir: 'income', single: 60)],
    [L('vendi a bike por 60 no pix', dir: 'income', single: 60)],
    [L('paguei o aluguel de 1500 dia 5 no pix'), L('1500', single: 1500, exp: diaN(5))],
    // edição/exclusão por nome com palavra de data no título
    [L('muda a pizzaria sábado pra 90', named: 'pizzaria')],
    [L('a pizzaria de sábado foi 90', named: 'pizzaria')],
    [L('muda o bar dia 7 pra 90', named: 'bar')],
    [L('muda o bar do dia 7 pra 90', named: 'bar')],
    [L('muda a padaria segunda via pra 90', named: 'padaria')],
    [L('muda o empório de quinta pra 90', named: 'emporio')],
    [L('muda o mercado de quinta pra 90', named: 'mercado')],
    [L('muda a feira de segunda pra 90', named: 'feira')],
    [L('muda o açougue pra 90', named: 'acougue')],
    [L('muda o cinema de ontem pra 90', named: 'cinema')],
    [L('muda a gasolina de segunda pra 90', named: 'gasolina')],
    [L('muda o sexta burger pra 90', named: 'sexta burger')],
    [L('apaga a pizzaria sábado', named: 'pizzaria'), L('sim', named: 'pizzaria')],
    [L('apaga o bar do dia 7', named: 'bar'), L('sim', named: 'bar')],
    [L('apaga o mercado de quinta', named: 'mercado'), L('sim', named: 'mercado')],
    [L('apaga a feira do dia 7', named: 'feira'), L('sim', named: 'feira')],
    [L('apaga o empório quinta', named: 'emporio'), L('sim', named: 'emporio')],
    // ── rodada de conclusão (2026-09-30) ──
    // "se"/"caso" + palavra -ar/-er/-ir/-or que NÃO é hipótese (fato registrável)
    [L('gastei 50 no mercado no pix, se quiser te mando a nota', dir: 'expense', single: 50, exp: t, hyp: false)],
    [L('paguei 200 no conserto da máquina no pix, se quebrar de novo tem garantia', dir: 'expense', single: 200, exp: t, hyp: false)],
    [L('recebi 500 de freela no pix, se eu tiver mais trabalho te aviso', dir: 'income', single: 500, exp: t, hyp: false)],
    [L('gastei 30 no cinema no pix e se quiser saber o filme era bom', dir: 'expense', single: 30, exp: t, hyp: false)],
    [L('paguei 45 no bar no pix; se for preciso divido depois', dir: 'expense', single: 45, exp: t, hyp: false)],
    [L('gastei 60 na farmácia no pix. se eu melhorar volto pra academia', dir: 'expense', single: 60, exp: t, hyp: false)],
    [L('gastei 70 no restaurante no pix, mas se pedir sobremesa é mais caro', dir: 'expense', single: 70, exp: t, hyp: false)],
    [L('paguei 120 de luz no pix, e se atrasar tem multa', dir: 'expense', single: 120, exp: t, hyp: false)],
    [L('gastei 40 no mercado no pix, se por acaso perguntarem', dir: 'expense', single: 40, exp: t, hyp: false)],
    [L('gastei 35 no mercado no pix, se o valor tiver errado eu corrijo', dir: 'expense', single: 35, exp: t, hyp: false)],
    [L('paguei 90 no Bar Se Beber Não Dirija no pix', dir: 'expense', single: 90, exp: t, hyp: false)],
    [L('paguei 300 do caso do seguro no pix', dir: 'expense', single: 300, exp: t, hyp: false)],
    [L('recebi 800 pelo caso que ganhei no pix', dir: 'income', single: 800, exp: t, hyp: false)],
    [L('gastei 40 em caso de emergência no pix', dir: 'expense', single: 40, exp: t, hyp: false)],
    [L('paguei 150 pro advogado no pix, esse caso tá caro', dir: 'expense', single: 150, exp: t, hyp: false)],
    // hipóteses que o detector não pega — e as cadeias que as completam
    [L('se o joão me pagar 200', hyp: true), L('no pix', hyp: true), L('mercado', hyp: true)],
    [L('gastaria 50 no mercado se tivesse desconto', hyp: true), L('no pix', hyp: true)],
    [L('supondo que eu gaste 200 no mercado no pix', hyp: true)],
    [L('digamos que eu pague 100 de luz no pix', hyp: true)],
    [L('imagina se eu gastar 500 no shopping no pix', hyp: true)],
    [L('quero gastar 300 no mercado no pix se der', hyp: true)],
    [L('vou comprar um tênis de 250 no pix se sobrar', hyp: true)],
    [L('compro um celular de 1500 no pix se o salário cair', hyp: true)],
    [L('quando o salário cair eu pago 1500 de aluguel no pix', hyp: true)],
    [L('e se o mercado der 300?', hyp: true)],
    [L('se o salário cair 4500 eu guardo 500', hyp: true)],
    [L('na hipótese de eu gastar 400 no mercado no pix', hyp: true)],
    [L('e se eu gastar 80 na farmácia'), L('no pix', hyp: true), L('farmácia', hyp: true)],
    [L('vou gastar 200 no mercado amanhã no pix', dir: 'expense', single: 200, ask: true)],
    // "me + verbo" que não é dinheiro entrando
    [L('o garçom me passou a conta de 80 e paguei no pix', dir: 'expense', single: 80)],
    [L('o mecânico me orçou 300 e paguei no pix', dir: 'expense', single: 300)],
    [L('me obrigaram a pagar 50 de multa no pix', dir: 'expense', single: 50)],
    [L('me fizeram pagar 30 de taxa no pix', dir: 'expense', single: 30)],
    [L('me assaltaram 200 no centro', dir: 'expense', single: 200), L('dinheiro', dir: 'expense', single: 200)],
    [L('o vendedor me empurrou um seguro de 90 no pix', dir: 'expense', single: 90)],
    [L('o joão me convenceu a gastar 200 no bar no pix', dir: 'expense', single: 200)],
    [L('me venderam um celular por 800 no pix', dir: 'expense', single: 800)],
    [L('a loja me mandou a fatura de 300', dir: 'expense', single: 300), L('no pix', dir: 'expense', single: 300)],
    [L('me passaram um orçamento de 400 e fechei no pix', dir: 'expense', single: 400)],
    [L('a vivo me aumentou 20 na conta e paguei no pix', dir: 'expense')],
    // 2+ valores: iguais, sem separador, título com número
    [L('uber 15 uber 20 no pix', dir: 'expense', values: [15, 20])],
    [L('gastei 20 no uber 20 no ifood no pix', dir: 'expense', values: [20, 20])],
    [L('gastei 30 no mercado e 30 no mercado de novo no pix', dir: 'expense', values: [30, 30])],
    [L('café 8 pão 12 no pix', dir: 'expense', values: [8, 12])],
    [L('paguei 50 de luz, 50 de água no boleto', dir: 'expense', values: [50, 50])],
    [L('recebi 100 do joão 100 da maria no pix', dir: 'income', values: [100, 100])],
    [L('almoço 32, janta 48 e café 10 no pix', dir: 'expense', values: [32, 48, 10])],
    [L('gastei 50 no mercado e dia 7 gastei 30 na farmácia no pix', dir: 'expense', values: [50, 30])],
    [L('gastei 50 no Bar Dia 7 e 30 na farmácia no pix', dir: 'expense', values: [50, 30])],
    [L('gastei 120 na Pizzaria Sábado e 40 no uber no pix', dir: 'expense', values: [120, 40])],
    [L('gastei 50 no mercado, dia 5, no pix', dir: 'expense', single: 50, exp: diaN(5))],
    // resposta a "quanto foi?" com data / dois valores
    [L('gastei no mercado no pix'), L('foi 50 anteontem', dir: 'expense', single: 50, exp: back(2), answer: true)],
    [L('gastei no mercado no pix'), L('50 dia 5', dir: 'expense', single: 50, exp: diaN(5), answer: true)],
    [L('gastei no mercado no pix'), L('50 na segunda', dir: 'expense', single: 50, exp: wdLast(1), answer: true)],
    [L('gastei no mercado no pix'), L('50 amanhã', dir: 'expense', single: 50, ask: true, answer: true)],
    [L('gastei no mercado no pix'), L('uns 50 ou 60', values: [50, 60])],
    [L('gastei no mercado no pix'), L('50 e 30', values: [50, 30])],
    [L('paguei o aluguel'), L('vendi a bike por 300 no pix', dir: 'income', single: 300)],
    [L('gastei na padaria segunda via no pix'), L('25', dir: 'expense', single: 25, exp: t, title: true, answer: true)],
    [L('gastei no totem do estacionamento no pix'), L('12', dir: 'expense', single: 12, exp: t, title: true, answer: true)],
    // palavra de data como pedaço de outra palavra / de um nome
    [L('gastei 50 no Bar Fim de Semana no pix', dir: 'expense', single: 50, exp: t, title: true)],
    [L('gastei 20 no Totem Lanches no pix', dir: 'expense', single: 20, exp: t, title: true)],
    [L('paguei 15 no totem do metrô no pix', dir: 'expense', single: 15, exp: t, title: true)],
    // edição por nome × categoria × dia da semana (fixtures: Uber e Bar Dia 7 anteontem, Posto ontem)
    [L('muda o cinema de segunda pra 90', named: 'cinema')],
    [L('apaga o cinema de segunda', named: 'cinema'), L('sim', named: 'cinema')],
    [L('muda o táxi de segunda pra 90', named: 'taxi')],
    [L('muda o remédio de sexta pra 90', named: 'remedio')],
    [L('muda a lanchonete de sexta pra 90', named: 'lanchonete')],
    [L('muda o posto de segunda pra 90', named: 'posto')],
    [L('muda o combustível de segunda pra 90', named: 'combustivel')],
    [L('apaga a gasolina de segunda', named: 'gasolina'), L('sim', named: 'gasolina')],
  ];
}

// ───────────────────────── relógio injetado no SpokenDayParser ─────────────────────────

class ClockCase {
  final String phrase;
  final DateTime? exp;
  final bool invalid;
  final bool future;
  ClockCase(this.phrase, this.exp, {this.invalid = false, this.future = false});
}

List<ClockCase> clockOracle(DateTime now) {
  final t = _day(now);
  DateTime back(int n) => DateTime(t.year, t.month, t.day - n);
  int wdBack(int wd) {
    final b = (t.weekday - wd) % 7;
    return b == 0 ? 7 : b;
  }

  DateTime? dia(int n) {
    var y = t.year, m = t.month;
    if (n > t.day) {
      m--;
      if (m == 0) {
        m = 12;
        y--;
      }
    }
    return (n < 1 || n > _daysIn(y, m)) ? null : DateTime(y, m, n);
  }

  DateTime? dm(int d, int m) {
    if (m < 1 || m > 12) return null;
    final ahead = m > t.month || (m == t.month && d > t.day);
    final y = ahead ? t.year - 1 : t.year;
    return (d < 1 || d > _daysIn(y, m)) ? null : DateTime(y, m, d);
  }

  final out = <ClockCase>[
    ClockCase('ontem', back(1)),
    ClockCase('anteontem', back(2)),
    ClockCase('hoje', t),
    ClockCase('amanha', DateTime(t.year, t.month, t.day + 1), future: true),
    ClockCase('depois de amanha', DateTime(t.year, t.month, t.day + 2), future: true),
    ClockCase('ha 1 dia', back(1)),
    ClockCase('ha 30 dias', back(30)),
    ClockCase('ha 365 dias', back(365)),
    ClockCase('ha 400 dias', null, invalid: true),
    ClockCase('domingo retrasado', back(wdBack(7) + 7)),
  ];
  for (final wd in _wdNames.entries) {
    final name = CategoryNameMatcher.foldAccents(wd.value);
    out.add(ClockCase(name, back(wdBack(wd.key))));
    out.add(ClockCase('$name passad${wd.key >= 6 ? 'o' : 'a'}', back(wdBack(wd.key))));
  }
  for (final n in [0, 1, 28, 29, 30, 31, 32]) {
    final d = dia(n);
    out.add(ClockCase('dia $n', d, invalid: d == null));
  }
  for (final p in [
    [31, 12], [1, 1], [29, 2], [30, 2], [28, 2], [31, 9], [1, 10], [30, 9], [15, 13], [0, 5],
  ]) {
    final d = dm(p[0], p[1]);
    out.add(ClockCase('${p[0].toString().padLeft(2, '0')}/${p[1].toString().padLeft(2, '0')}', d, invalid: d == null));
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;
  final totals = <String, int>{};

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  test('CHAOS-A casos-alvo', () async {
    var n = 0, bad = 0;
    for (final seq in targeted()) {
      n += seq.length;
      final res = await runA(engine, fixed: seq);
      // resposta final (para leitura humana)
      final repo = await freshRepo();
      final sim = Sim3(engine, repo);
      final replies = <String>[];
      final beforeIds = repo.transactions.map((e) => e.id).toSet();
      for (final lt in seq) {
        replies.add(sim.send(lt.text).short);
      }
      final added = repo.transactions.where((x) => !beforeIds.contains(x.id)).map((x) => '${x.title} ${x.amount} ${x.type.name} ${ddmmyy(x.date)}${x.isRecurrent ? ' REC' : ''}').toList();
      final label = seq.map((e) => '"${e.text}"').join(' ⏎ ');
      print('CHAOS-A|ALVO| $label ⇒ ${replies.last} ⇒ novos=$added');
      for (final x in res.v) {
        bad++;
        totals['alvo:${x.kind}'] = (totals['alvo:${x.kind}'] ?? 0) + 1;
        print('CHAOS-A|ALVO-V| ${x.kind}: $label :: ${x.detail}');
      }
    }
    print('CHAOS-A|RESUMO| alvo: ${targeted().length} sequências, $n turnos, $bad violações');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('CHAOS-A relógio injetado no SpokenDayParser (lançar)', () {
    final clocks = [
      DateTime(2026, 10, 1, 9), DateTime(2026, 9, 1, 0, 0, 1), DateTime(2028, 2, 29, 12), DateTime(2028, 3, 1, 8), DateTime(2027, 3, 1, 8),
      DateTime(2026, 12, 31, 23, 59, 59), DateTime(2027, 1, 1, 0, 0, 0), DateTime(2026, 9, 27, 12), DateTime(2026, 9, 28, 12), DateTime(2026, 9, 29, 12),
      DateTime(2027, 2, 28, 12), DateTime(2026, 3, 31, 12),
    ];
    var n = 0, bad = 0;
    for (final now in clocks) {
      for (final c in clockOracle(now)) {
        n++;
        // Frase como o motor a vê: dentro de uma frase de lançamento.
        final phrase = 'gastei 50 no mercado ${c.phrase} no pix';
        final res = SpokenDayParser.parse(SpokenDayParser.normalizeWeekdays(phrase), now: now, allowFuture: true);
        final got = res?.day;
        String problem = '';
        if (c.invalid) {
          if (res == null || res.invalid == null) problem = 'data inexistente aceita: ${got == null ? 'null' : ddmmyy(got.start)}';
        } else if (got == null) {
          problem = 'não leu a data (${res?.invalid})';
        } else if (!got.isRange && _day(got.start) != c.exp) {
          problem = 'leu ${ddmmyy(got.start)}, esperado ${ddmmyy(c.exp!)}';
        } else if (!c.future && got.offsetFrom(now) > 0) {
          problem = 'data futura ${ddmmyy(got.start)}';
        }
        // Invariante do motor: offset <= 0 grava; > 0 pergunta.
        if (problem.isEmpty && got != null && !c.future && got.offsetFrom(now) > 0) problem = 'offset>0';
        if (problem.isNotEmpty) {
          bad++;
          print('CHAOS-A|RELOGIO-V| hoje=${ddmmyy(now)} ${now.hour}:${now.minute}:${now.second} "$phrase" → $problem');
        }
      }
      // O "dia N" do título também é lido como data pelo parser compartilhado.
      for (final title in ['no Bar Dia 7', 'na Pizzaria Sábado', 'na Padaria Segunda Via', 'no Sexta Burger', 'na loja nota 10/10', 'em 1/2 kg de queijo']) {
        n++;
        final r = SpokenDayParser.parse(SpokenDayParser.normalizeWeekdays(CategoryNameMatcher.foldAccents('gastei 50 $title no pix'.toLowerCase())), now: now, allowFuture: true);
        if (r != null) {
          stat('titulo_lido_como_data');
          print('CHAOS-A|RELOGIO-T| hoje=${ddmmyy(now)} "gastei 50 $title no pix" → ${r.day == null ? 'inválida: ${r.invalid}' : ddmmyy(r.day!.start)} (matched "${r.day?.matched ?? r.matched}")');
        }
      }
    }
    print('CHAOS-A|RESUMO| relógio: ${clocks.length} relógios, $n leituras, $bad divergências do oráculo');
  });

  test('CHAOS-A relógio injetado na referência (editar/apagar por nome × dia)', () async {
    // O motor lê "agora" do relógio real; o CesarAssistant (referência de
    // edição/exclusão) aceita relógio injetado. Aqui os registros são datados
    // em torno de cada "hoje" injetado e os comandos só podem atingir o
    // registro do nome dito (e do dia dito, quando há dia).
    final clocks = <String, DateTime>{
      '1º do mês (qui)': DateTime(2026, 10, 1, 9),
      '1º do mês pós-fev (seg)': DateTime(2027, 3, 1, 9),
      '29/02 (ter)': DateTime(2028, 2, 29, 12),
      '31/12 (qui) 23:59': DateTime(2026, 12, 31, 23, 59, 59),
      'domingo': DateTime(2026, 10, 4, 12),
      'segunda': DateTime(2026, 10, 5, 8),
    };
    var n = 0, bad = 0;
    for (final ck in clocks.entries) {
      final now = ck.value;
      final t = _day(now);
      DateTime at(DateTime d) => DateTime(d.year, d.month, d.day, 0, 30);
      final ontem = DateTime(t.year, t.month, t.day - 1);
      final barDay = ontem.day == 7 ? DateTime(t.year, t.month, t.day - 2) : ontem;
      final fx = <FinancialTransaction>[
        FinancialTransaction(id: 'ck-feira-seg', title: 'Feira', amount: 61, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: at(wdLast(1, now))),
        FinancialTransaction(id: 'ck-feira-sab', title: 'Feira', amount: 62, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: at(wdLast(6, now))),
        FinancialTransaction(id: 'ck-padaria-sv', title: 'Padaria Segunda Via', amount: 63, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: at(wdLast(3, now))),
        FinancialTransaction(id: 'ck-pizzaria-sab', title: 'Pizzaria Sábado', amount: 64, type: TransactionType.expense, category: 'food', paymentMethod: 'pix', date: at(wdLast(5, now))),
        FinancialTransaction(id: 'ck-bar-dia7', title: 'Bar Dia 7', amount: 65, type: TransactionType.expense, category: 'leisure', paymentMethod: 'pix', date: at(barDay)),
        FinancialTransaction(id: 'ck-uber-seg', title: 'Uber', amount: 66, type: TransactionType.expense, category: 'transport', paymentMethod: 'pix', date: at(wdLast(1, now))),
        FinancialTransaction(id: 'ck-posto-ontem', title: 'Posto', amount: 67, type: TransactionType.expense, category: 'transport', paymentMethod: 'pix', date: at(ontem)),
        FinancialTransaction(id: 'ck-mercado-dia1', title: 'Mercado', amount: 68, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: at(diaN(1, now)!)),
      ];
      bool sameDay(FinancialTransaction x, DateTime? d) => d != null && _day(x.date) == _day(d);
      // comando → (turnos, quem pode ser atingido)
      final cases = <List<Object>>[
        [['muda a feira de segunda pra 91'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, wdLast(1, now))],
        [['apaga a feira de segunda', 'sim'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, wdLast(1, now))],
        [['muda a feira de sábado pra 92'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, wdLast(6, now))],
        [['muda a feira de ontem pra 93'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, ontem)],
        [['apaga a feira de ontem', 'sim'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, ontem)],
        [['muda a padaria segunda via pra 94'], (FinancialTransaction x) => x.title.startsWith('Padaria')],
        [['muda a pizzaria sábado pra 95'], (FinancialTransaction x) => x.title.startsWith('Pizzaria')],
        [['apaga a pizzaria sábado', 'sim'], (FinancialTransaction x) => x.title.startsWith('Pizzaria')],
        [['muda o bar dia 7 pra 96'], (FinancialTransaction x) => x.title.startsWith('Bar')],
        [['apaga o bar do dia 7', 'sim'], (FinancialTransaction x) => x.title.startsWith('Bar')],
        [['muda o uber de segunda pra 97'], (FinancialTransaction x) => x.title == 'Uber' && sameDay(x, wdLast(1, now))],
        [['muda a gasolina de segunda pra 98'], (FinancialTransaction x) => x.title == 'Posto' && sameDay(x, wdLast(1, now))],
        [['muda o táxi de segunda pra 99'], (FinancialTransaction x) => false],
        [['muda o mercado do dia 1 pra 100'], (FinancialTransaction x) => x.title.contains('ercado') && x.date.day == 1],
        [['muda o mercado de ontem pra 101'], (FinancialTransaction x) => x.title.contains('ercado') && sameDay(x, ontem)],
        [['apaga o mercado do dia 1', 'sim'], (FinancialTransaction x) => x.title.contains('ercado') && x.date.day == 1],
        [['muda a feira do dia 29 pra 102'], (FinancialTransaction x) => x.title == 'Feira' && x.date.day == 29],
        [['muda a feira do dia 31 pra 103'], (FinancialTransaction x) => x.title == 'Feira' && x.date.day == 31],
        [['muda a feira de 29/02 pra 104'], (FinancialTransaction x) => x.title == 'Feira' && x.date.day == 29 && x.date.month == 2],
        [['muda a feira de 31/12 pra 105'], (FinancialTransaction x) => x.title == 'Feira' && x.date.day == 31 && x.date.month == 12],
        [['muda o cinema de segunda pra 106'], (FinancialTransaction x) => false],
      ];
      for (final c in cases) {
        final turns = c[0] as List<String>;
        final allowed = c[1] as bool Function(FinancialTransaction);
        SharedPreferences.setMockInitialValues({});
        final repo = FinancialRepository();
        await repo.initialize();
        for (final x in fx) {
          repo.addTransaction(x);
        }
        final sim = Sim3(engine, repo, now: () => now);
        var prevText = '';
        for (final turn in turns) {
          n++;
          final before = {for (final x in repo.transactions) x.id: x};
          final beforeSnap = Snap3.of(repo);
          final r = sim.send(turn);
          final afterSnap = Snap3.of(repo);
          final removed = beforeSnap.tx.keys.where((k) => !afterSnap.tx.containsKey(k)).toList();
          final changed = beforeSnap.tx.keys.where((k) => afterSnap.tx.containsKey(k) && afterSnap.tx[k] != beforeSnap.tx[k]).toList();
          final label = turns.map((e) => '"$e"').join(' ⏎ ');
          for (final k in [...removed, ...changed]) {
            final x = before[k]!;
            if (allowed(x)) continue;
            final shown = prevText.contains(x.title) && r.route == 'deleted';
            bad++;
            print('CHAOS-A|REFCLOCK-V| ${shown ? 'confirmou_outro' : 'atingiu_outro'} hoje=${ck.key} ${ddmmyy(now)}: $label → [${r.route}] '
                '${removed.contains(k) ? 'apagou' : 'mudou'} ${x.title} ${CesarText.money(x.amount)} de ${ddmmyy(x.date)} :: ${r.text.replaceAll('\n', ' ')}');
          }
          // data nova no futuro / inexistente gravada
          for (final k in changed) {
            final d = _day(DateTime.parse((jsonDecode(afterSnap.tx[k]!) as Map)['date'] as String));
            if (d.isAfter(t)) {
              bad++;
              print('CHAOS-A|REFCLOCK-V| data_futura hoje=${ck.key}: $label → ${describeTx(afterSnap.tx[k]!)}');
            }
          }
          prevText = r.text;
          print('CHAOS-A|REFCLOCK| hoje=${ck.key} ${ddmmyy(now)} "$turn" → ${r.short}');
        }
      }
    }
    print('CHAOS-A|RESUMO| referência×relógio: ${clocks.length} relógios, $n turnos, $bad violações');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('CHAOS-A fuzz (seeds novas 20261100+n)', () async {
    final sw = Stopwatch()..start();
    final seeds = int.tryParse(Platform.environment['A_SEEDS'] ?? '') ?? 24;
    final length = int.tryParse(Platform.environment['A_LEN'] ?? '') ?? 200;
    var turns = 0;
    final firstBy = <String, List<LT>>{};
    final firstSeed = <String, int>{};
    final countBy = <String, int>{};
    final distinct = <String, Set<String>>{};
    for (var n = 1; n <= seeds; n++) {
      final seed = 20261100 + n;
      final res = await runA(engine, gen: GenA(Random(seed), length));
      turns += res.sent.length;
      for (final x in res.v) {
        countBy[x.kind] = (countBy[x.kind] ?? 0) + 1;
        (distinct[x.kind] ??= {}).add(res.sent[x.turn].text.replaceAll(RegExp(r'\d+'), '#'));
        if (!firstBy.containsKey(x.kind)) {
          firstBy[x.kind] = res.sent;
          firstSeed[x.kind] = seed;
          print('CHAOS-A|FUZZ| primeira ${x.kind} seed=$seed turno ${x.turn + 1}: ${x.detail}');
        }
      }
      print('CHAOS-A|FUZZ| seed=$seed turnos=${res.sent.length} violações=${res.v.length} (${sw.elapsedMilliseconds} ms)');
    }
    print('CHAOS-A|RESUMO| fuzz: $seeds seeds × $length = $turns turnos; ${sw.elapsedMilliseconds} ms');
    print('CHAOS-A|RESUMO| violações por tipo: $countBy');
    for (final e in distinct.entries) {
      print('CHAOS-A|FUZZ-FORMAS| ${e.key} (${e.value.length} formas): ${e.value.take(25).join(' | ')}');
    }
    final routes = routeCount.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    print('CHAOS-A|RESUMO| rotas: ${routes.map((e) => '${e.key}=${e.value}').join(' ')}');
    print('CHAOS-A|RESUMO| estatísticas: $statCount');
    for (final kind in firstBy.keys) {
      final m = await minimizeA(engine, firstBy[kind]!, kind, sw, sw.elapsedMilliseconds + 20000);
      final res = await runA(engine, fixed: m);
      final x = res.v.firstWhere((e) => e.kind == kind, orElse: () => VA(kind, '(não reproduziu)', -1));
      print('CHAOS-A|MIN| $kind (seed ${firstSeed[kind]}, ${m.length} turnos): ${m.map((e) => '"${e.text}"').join(' ⏎ ')}  ⇒  ${x.detail}');
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}
