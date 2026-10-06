// Portão de qualidade, etapa 5 (generalização) — Item 2, lote A do PLANO_CESAR.md.
//
// Prova ou refuta que as 7 correções P0 do lote A (docs/qa/findings-conversa-r3.md,
// docs/qa/findings-caos-r3.md; testes em test/cesar_p0_r3_test.dart) GENERALIZAM,
// usando SÓ frases inéditas — nenhuma repete nem parafraseia de perto
// cesar_p0_r3_test.dart, as baterias r1/r2/r3, caos ou holdout.
//
// NÃO é teste de regressão: não usa `expect`, nunca falha a suíte. Imprime:
//   ACCA_FAIL|eixo|id|sev|entrada|esperado|obtido
//   ACCA_AXIS|eixo|passou/total|pct
//   ACCA_TOTAL|passou/total|pct
//
// Rodar:
//   flutter test test/_qa/acceptance_lote_a_probe_test.dart 2>&1 | grep -E "ACCA_"
//
// Cada caso roda num repositório limpo (sem dados de demonstração) com o
// `Sim3` de chaos_r3_support.dart, que espelha `_sendMessage` do chat com o
// CesarAssistant real. Quando o César só pergunta a forma de pagamento /
// parcelas / prazo da recorrência (o que não é o objeto do eixo), a sonda
// responde como o usuário responderia ("pix", "à vista", "sem prazo") —
// esses turnos extras aparecem na saída entre colchetes.
//
// Datas: eixos 1–5 usam DateTime.now() (o motor não aceita relógio); as
// expectativas são calculadas com as mesmas regras do SpokenDayParser. O
// eixo 6 usa relógio fixo no CesarAssistant: terça 2026-09-29 12:00 (casos wed*: quarta 30/09).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/persistence_service.dart';

import 'chaos_r3_support.dart';

class _NullPersistence extends PersistenceService {
  @override
  Future<bool> hasPersistedData() async => false;
  @override
  Future<void> markSeeded() async {}
  @override
  Future<void> saveTransactions(items) async {}
  @override
  Future<void> saveReminders(items) async {}
  @override
  Future<void> saveBudgets(items) async {}
  @override
  Future<void> saveGoals(items) async {}
  @override
  Future<void> saveCategoryOverrides(Map<String, String> overrides) async {}
  @override
  Future<void> clearAll() async {}
}

// ─────────────────────────── modelo ───────────────────────────

class Outcome {
  final String sev;
  final String got;
  Outcome(this.sev, this.got);
}

class Ctx {
  final Sim3 sim;
  final List<String> turns;
  final List<R3Reply> replies;
  final Map<String, String> before;
  Ctx(this.sim, this.turns, this.replies, this.before);

  FinancialRepository get repo => sim.repo;
  Map<String, String> get after => {for (final t in repo.transactions) t.id: jsonEncode(t.toJson())};
  List<FinancialTransaction> get added => repo.transactions.where((t) => !before.containsKey(t.id)).toList();
  List<String> get removed => before.keys.where((k) => !after.containsKey(k)).toList();
  List<String> get changed => after.keys.where((k) => before.containsKey(k) && before[k] != after[k]).toList();
  R3Reply get lastReply => replies.last;
  R3Reply get firstReply => replies.first;
  FinancialTransaction? byId(String id) => repo.transactions.where((t) => t.id == id).firstOrNull;

  String get pendingInfo {
    final a = sim.active;
    if (sim.pendingBatch != null) return 'lote pendente(${sim.pendingBatch!.map((d) => '${d.amount}/${d.missingSlots}').join(';')})';
    if (a != null && !a.isComplete) return 'rascunho pendente ${a.intent} ${a.amount} missing=${a.missingSlots}';
    return '';
  }

  String get summary {
    final add = added.map((t) => '+${t.type.name}:${t.amount}:${t.category}:${t.paymentMethod}:${_dm(t.date)}').join(', ');
    final rem = removed.map((id) => '-$id').join(', ');
    final chg = changed.map((id) {
      final t = byId(id)!;
      return '~$id=${t.amount}:${t.paymentMethod}:${_dm(t.date)}';
    }).join(', ');
    final r = replies.map((r) => r.short).join(' ⏎ ');
    return '{${[add, rem, chg].where((s) => s.isNotEmpty).join(' ')}} $pendingInfo | $r';
  }
}

typedef Check = Outcome? Function(Ctx c);

class Case {
  final int axis;
  final String id;
  final List<String> turns;
  final String expected;
  final Check check;
  final bool settle;
  final bool fixedClock;
  final bool feature; // "sim" à sugestão (registrar à parte)
  final DateTime? clock; // relógio do eixo 6 (padrão: _fixedNow)
  Case(this.axis, this.id, this.turns, this.expected, this.check, {this.settle = true, this.fixedClock = false, this.feature = false, this.clock});
}

// ─────────────────────────── datas ───────────────────────────

final DateTime _now = DateTime.now();
DateTime get _today => DateTime(_now.year, _now.month, _now.day);
String _dm(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
int _offsetOf(DateTime d) => DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(_today.year, _today.month, _today.day)).inDays;

int backTo(int weekday) {
  var b = (_today.weekday - weekday) % 7;
  if (b == 0) b = 7;
  return -b;
}

int dayN(int n) => _offsetOf(n <= _today.day ? DateTime(_today.year, _today.month, n) : DateTime(_today.year, _today.month - 1, n));

int ddmm(int d, int m) {
  final ahead = m > _today.month || (m == _today.month && d > _today.day);
  return _offsetOf(DateTime(ahead ? _today.year - 1 : _today.year, m, d));
}

int lastMonthDay(int d) => _offsetOf(DateTime(_today.year, _today.month - 1, d));

bool _sameDay(DateTime a, int offset) {
  final e = DateTime(_today.year, _today.month, _today.day + offset);
  return a.year == e.year && a.month == e.month && a.day == e.day;
}

// ─────────────────────────── verificadores ───────────────────────────

Outcome _fail(String sev, Ctx c, [String note = '']) => Outcome(sev, '${note.isEmpty ? '' : '$note — '}${c.summary}');

/// Exatamente um lançamento novo, do tipo/valor dados; nada editado/apagado.
Check one(String type, double amount, {Set<String>? cats, String? notCat, int? day, String catSev = 'P2'}) => (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
      final a = c.added;
      if (a.isEmpty) {
        final asked = c.pendingInfo.isNotEmpty;
        final miss = c.sim.active?.missingSlots ?? const <String>[];
        // Perguntar de novo algo que o usuário já disse (tipo, data) é atrito, não perda.
        // Pedir para separar ("split") num controle de 1 lançamento também é atrito conservador.
        final sev = miss.isNotEmpty && miss.every((m) => m == 'type' || m == 'date' || m == 'split') ? 'P2' : 'P1';
        return _fail(sev, c, asked ? 'não registrou, ficou perguntando' : 'não registrou');
      }
      if (a.length > 1) return _fail('P0', c, 'registrou ${a.length} lançamentos');
      final t = a.single;
      if (t.type.name != type) return _fail('P0', c, 'tipo errado');
      if ((t.amount - amount).abs() > 0.005) return _fail('P0', c, 'valor errado');
      if (day != null && !_sameDay(t.date, day)) return _fail('P0', c, 'data errada (esperado ${_dm(_today.add(Duration(days: day)))})');
      if (notCat != null && t.category == notCat) return _fail('P1', c, 'categoria herdada do rascunho descartado');
      if (cats != null && !cats.contains(t.category)) {
        // Categoria desconhecida (perguntou e o usuário disse "outros") é lacuna de vocabulário, não fusão.
        return _fail(t.category == 'expense_other' ? 'P3' : catSev, c, 'categoria fora de $cats');
      }
      return null;
    };

/// Receita informal: precisa sair receita com o valor.
Check income(double amount) => one('income', amount, cats: const {'salary', 'income_other', 'investment'});

/// Controle de despesa: não pode virar receita.
Check expense(double amount) => one('expense', amount);

/// Vários lançamentos, valores (em ordem) e tipos.
Check many(List<double> amounts, {List<String>? types}) => (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
      final a = c.added;
      if (a.isEmpty) return _fail('P1', c, c.pendingInfo.isEmpty ? 'não registrou' : 'não registrou, ficou perguntando');
      final got = a.map((t) => t.amount).toList();
      final gotSorted = [...got]..sort();
      final expSorted = [...amounts]..sort();
      final same = gotSorted.length == expSorted.length && List.generate(expSorted.length, (i) => (gotSorted[i] - expSorted[i]).abs() < 0.005).every((x) => x);
      if (!same) return _fail(a.length < amounts.length && a.length == 1 ? 'P0' : 'P0', c, 'itens ${got.join('+')} ≠ ${amounts.join('+')}');
      if (types != null) {
        final byAmount = {for (var i = 0; i < amounts.length; i++) amounts[i]: types[i]};
        for (final t in a) {
          if (byAmount[t.amount] != t.type.name) return _fail('P0', c, 'tipo errado no item ${t.amount}');
        }
      } else if (a.any((t) => t.type != TransactionType.expense)) {
        return _fail('P0', c, 'item não-despesa');
      }
      if (a.any((t) => t.paymentMethod == 'unknown')) return _fail('P2', c, 'item sem forma de pagamento');
      return null;
    };

/// Hipótese: nada gravado; o César responde (não pergunta slot nem "não entendi").
Outcome? hypothesis(Ctx c) {
  if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'hipótese gravou/alterou dados');
  final r = c.lastReply.route;
  if (r == 'ask' || c.pendingInfo.isNotEmpty) return _fail('P1', c, 'tratou hipótese como lançamento (perguntou slot)');
  if (r == 'unknown') return _fail('P2', c, 'não entendeu a hipótese');
  return null;
}

/// Não grava nada e fica perguntando a data.
Outcome? asksDate(Ctx c) {
  if (c.added.isNotEmpty) {
    final t = c.added.first;
    return _fail('P0', c, 'gravou com data ${_dm(t.date)} sem perguntar');
  }
  final a = c.sim.active;
  if (a == null || a.isComplete || !a.missingSlots.contains('date')) return _fail('P1', c, 'não perguntou a data');
  return null;
}

/// Recorrente com dia de vencimento N.
Check recurring(String type, double amount, int due) => (c) {
      final base = one(type, amount)(c);
      final d = c.sim.last;
      if (c.added.isEmpty) return base;
      if (base != null && base.sev == 'P0') return base;
      if (d == null || !d.isRecurrent) return _fail('P0', c, 'virou lançamento único (recorrência perdida)');
      if (d.dueDay != due) return _fail('P0', c, 'dia de vencimento ${d.dueDay} ≠ $due');
      return base;
    };

/// Lançamento único com data (não recorrente).
Check onceOn(String type, double amount, int day) => (c) {
      final base = one(type, amount, day: day)(c);
      if (base != null) return base;
      final d = c.sim.last;
      if (d != null && d.isRecurrent) return _fail('P1', c, 'virou recorrente');
      return null;
    };

/// Comentário no meio de um rascunho: nada gravado.
Outcome? nothingSaved(Ctx c) {
  if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'gravou/alterou dados');
  return null;
}

// ── eixo 6 ──
final DateTime _fixedNow = DateTime(2026, 9, 29, 12); // terça
final DateTime _wedNow = DateTime(2026, 9, 30, 12); // quarta ("hoje" do portão)

FinancialTransaction _tx(String id, String title, double amount, DateTime date, String cat) =>
    FinancialTransaction(id: id, title: title, amount: amount, type: TransactionType.expense, category: cat, paymentMethod: 'pix', date: date);

List<FinancialTransaction> _seed6() => [
      _tx('hort', 'Hortifruti', 45, DateTime(2026, 9, 26, 10), 'supermarket'), // sábado
      _tx('empo', 'Empório', 38, DateTime(2026, 9, 24, 10), 'supermarket'), // quinta
      _tx('cine', 'Cinema', 52, DateTime(2026, 9, 25, 20), 'leisure'), // sexta
      _tx('estac', 'Estacionamento', 15, DateTime(2026, 9, 25, 19), 'transport'), // sexta
      _tx('bar', 'Bar do Zé', 64, DateTime(2026, 9, 27, 21), 'leisure'), // domingo
      _tx('farm', 'Farmácia', 33, DateTime(2026, 9, 28, 9), 'health'), // segunda
      _tx('taxi', 'Táxi', 27, DateTime(2026, 9, 23, 8), 'transport'), // quarta
      _tx('dent', 'Dentista', 250, DateTime(2026, 9, 15, 14), 'health'), // terça 15/09
      _tx('lanch', 'Lanchonete', 19, DateTime(2026, 9, 29, 11), 'leisure'), // hoje
    ];

/// Nome não bate na data: nada muda; a resposta cita [title] e não cita [distractor].
Check untouched(String title, {String? distractor}) => (c) {
      if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou dados sem confirmação');
      if (c.pendingInfo.isNotEmpty) return _fail('P1', c, 'virou lançamento novo pendente');
      final text = c.replies.map((r) => r.text).join(' ');
      if (distractor != null && text.contains(distractor)) return _fail('P2', c, 'ofereceu o distrator $distractor');
      if (!text.contains(title)) return _fail('P2', c, 'não sugeriu $title');
      return null;
    };

/// Só o registro [id] mudou (ou foi apagado se [deleted]); verificação extra em [ok].
Check onlyThis(String id, {bool deleted = false, bool Function(FinancialTransaction t)? ok}) => (c) {
      if (c.added.isNotEmpty) return _fail('P0', c, 'criou lançamento novo');
      final others = [...c.removed, ...c.changed].where((x) => x != id).toList();
      if (others.isNotEmpty) return _fail('P0', c, 'mexeu em $others');
      if (deleted) {
        if (!c.removed.contains(id)) return _fail('P1', c, 'não apagou $id');
        return null;
      }
      if (!c.changed.contains(id)) return _fail('P1', c, 'não alterou $id');
      if (ok != null && !ok(c.byId(id)!)) return _fail('P0', c, 'alterou $id com valor errado');
      return null;
    };

// ─────────────────────────── casos ───────────────────────────

List<Case> buildCases() {
  final cs = <Case>[];
  void add(int axis, String id, List<String> turns, String exp, Check chk, {bool settle = true, bool fixed = false, bool feature = false, DateTime? clock}) =>
      cs.add(Case(axis, id, turns, exp, chk, settle: settle, fixedClock: fixed, feature: feature, clock: clock));

  // ── Eixo 1: receita informal + controles de despesa ──
  const inc = <String, double>{
    'o patrão soltou meu pagamento, 2800 na conta': 2800,
    'descolei um trampo e ganhei 350 no pix': 350,
    'o cliente acertou comigo 900 no pix': 900,
    'rolou um extra de 220 no fim de semana, veio no pix': 220,
    'tirei 400 fazendo corrida de aplicativo no fds': 400,
    'faturei 1200 com as vendas da loja': 1200,
    'levantei 500 vendendo roupa usada no brechó': 500,
    'recebi uma bolada de 3000 do acordo trabalhista': 3000,
    'o inquilino depositou 1100 do aluguel': 1100,
    'chegou o reembolso de 180 da firma': 180,
    'entrou um dinheirinho de 70 da rifa': 70,
    'o banco me devolveu 45 de tarifa cobrada errado': 45,
    'ganhei 50 conto no bolão da firma': 50,
    'meu pai me deu uma força de 250 no pix': 250,
    'minha madrinha me presenteou com 100 reais': 100,
    'caiu o vale alimentação, 600': 600,
    'o pix da venda da bike chegou, 850': 850,
    'passei meu celular velho pra frente por 700 no pix': 700,
    'o freela pagou 480 hoje': 480,
    'entrou mil e quinhentos do salário agora de manhã': 1500,
    'ganhei duzentos e cinquenta reais de comissão': 250,
    'entrou oitocentos na conta do freela': 800,
    'caiu dois mil e cem do salário': 2100,
    'arranjei 150 conto fazendo faxina': 150,
    'bati 300 de gorjeta essa semana': 300,
    'o chefe me adiantou 600 do mês': 600,
    'embolsei 200 de comissão': 200,
    'a dona do bar me pagou 150 pela diária': 150,
    'meu cunhado me repassou 90 da vaquinha no pix': 90,
    'vendi uns doces e apurei 130 no dinheiro': 130,
  };
  var n = 0;
  inc.forEach((p, v) => add(1, 'inc${++n}', [p], 'receita $v', income(v)));
  const out = <String, double>{
    'o app levou 50 de taxa de adesão no pix': 50,
    'caiu a fatura de 300': 300,
    'vendi… não, comprei um fone de 150 no pix': 150,
    'o encanador me cobrou 180 no dinheiro': 180,
    'o posto me passou a perna, paguei 250 de gasolina no débito': 250,
    'a academia me debitou 99 no crédito à vista': 99,
    'caiu o débito automático de 89 da internet': 89,
    'ganhei uma multa de 195 no pix': 195,
    'recebi a conta de luz de 140, paguei no pix': 140,
    'recebi uma cobrança de 75 do condomínio no boleto': 75,
    'me venderam um pneu por 320 no débito': 320,
    'fiz um pix de 90 pro dentista': 90,
    'caiu o boleto do seguro, 210': 210,
    'tomei uma multa de 130 no pix': 130,
  };
  n = 0;
  out.forEach((p, v) => add(1, 'exp${++n}', [p], 'despesa $v (nunca receita)', expense(v)));

  // ── Eixo 2: multi-lançamento + controles de 2 números ──
  final multi = <String, List<double>>{
    'gastei 18 no estacionamento e 42 no almoço no pix': [18, 42],
    'paguei 60 de internet, 95 de água e 140 de luz no boleto': [60, 95, 140],
    'uber 22 + lanche 17 no pix': [22, 17],
    'mercado 150; farmácia 40 no débito': [150, 40],
    'no pix: 30 de pão e 12 de leite': [30, 12],
    'gastei 40 no cinema e mais 25 de pipoca no crédito à vista': [40, 25],
    'fui na feira e gastei 35, depois no açougue mais 80, tudo no dinheiro': [35, 80],
    'gastei cinquenta no bar e trinta no uber no pix': [50, 30],
    'R\$ 15,90 de sorvete e R\$ 8,50 de água no dinheiro': [15.9, 8.5],
    'paguei 1.200 de aluguel e 350 de condomínio no pix': [1200, 350],
    'almocei por 35 e jantei por 50 no débito': [35, 50],
    'gasolina 200 / lava-jato 40 no pix': [200, 40],
    'gastei 25 com cerveja e 15 com petisco no dinheiro': [25, 15],
    'coloquei 80 no bilhete único e gastei 20 de lanche no pix': [80, 20],
    'tomei um café de 7 e comi um pão de 5 no dinheiro': [7, 5],
    'comprei 2 kg de carne por 70 e carvão por 25 no débito': [70, 25],
    'shampoo 19, sabonete 4, pasta de dente 8 no pix': [19, 4, 8],
    'hoje: ônibus 5, almoço 28, café 6, tudo no débito': [5, 28, 6],
  };
  n = 0;
  multi.forEach((p, v) => add(2, 'multi${++n}', [p], '${v.length} despesas ${v.join('+')}', many(v)));
  add(2, 'multi-mix1', ['recebi 500 de freela e gastei 120 no mercado, tudo no pix'], 'receita 500 + despesa 120',
      many([500, 120], types: ['income', 'expense']));
  add(2, 'multi-mix2', ['ganhei 60 de caixinha e paguei 20 de pedágio no pix'], 'receita 60 + despesa 20',
      many([60, 20], types: ['income', 'expense']));
  const single = <String, double>{
    'paguei 50 do apartamento 302': 50,
    'comprei 2 pizzas por 80 no pix': 80,
    'gastei 30 no dia 15 no pix': 30,
    'paguei 4,50 no ônibus da linha 175 no dinheiro': 4.5,
    'comprei um pneu aro 15 por 320 no débito': 320,
    'gastei 60 no mercado da rua 7 no pix': 60,
    'paguei 90 no presente de 30 anos da Ana no pix': 90,
    'comprei 3 cervejas de 600ml por 27 no dinheiro': 27,
    'gastei 12 no ônibus das 18h no dinheiro': 12,
    'comprei uma tv de 50 polegadas por 2500 no pix': 2500,
    'paguei 150 na consulta do dia 20 no pix': 150,
    'comprei uma capinha pro iphone 13 por 35 no pix': 35,
    'paguei 70 de uber pro terminal 2 no crédito à vista': 70,
    'comprei 4 pães por 6 no dinheiro': 6,
    'gastei 25 no lanche às 15h30 no pix': 25,
    'paguei 1.500 de aluguel do apto 12 no pix': 1500,
    'comprei 10 litros de gasolina por 62 no débito': 62,
    'paguei 40 no corte de cabelo, 2 horas de espera, no pix': 40,
  };
  n = 0;
  single.forEach((p, v) => add(2, 'single${++n}', [p], 'UM lançamento de $v', expense(v)));

  // ── Eixo 3: hipóteses × controles ──
  const hyp = [
    'se eu pedir um ifood de 60 hoje, estouro o orçamento?',
    'supondo que eu gaste 500 no mercado, quanto sobra?',
    'e se eu comprar um notebook de 4000 em 8x?',
    'caso eu pague 250 de ipva no pix, fico negativo?',
    'imagina se eu gastasse 1000 numa viagem',
    'se eu fosse comprar um sofá de 2000, dava?',
    'digamos que eu gaste 80 no cinema, ainda cabe?',
    'se eu investir 300 por mês, quanto junto em um ano?',
    'se meu salário fosse 5000, quanto sobraria?',
    'se amanhã eu pagar 90 de luz, ainda fico no azul?',
    'quanto ficaria uma geladeira de 2800 em 10 vezes?',
    'caso a gente viaje e gaste 1500, dá?',
    'se o conserto sair 600, eu consigo pagar?',
    'se eu comprar uma bike de 1200 no crédito em 4x, como fica?',
    'suponha que eu pague 150 de multa, o que acontece com meu saldo?',
    'se eu gastasse 40 por dia de almoço, quanto dá no mês?',
    'se eu receber 800 de freela, quanto fico?',
    'caso eu ganhe 1000 de bônus, dá pra quitar o cartão?',
    'se eu trocar de celular por um de 3000, compensa?',
    'e se eu pegar um uber de 70 pra ir no show?',
  ];
  n = 0;
  for (final h in hyp) {
    add(3, 'hyp${++n}', [h], 'não grava; responde a hipótese', hypothesis, settle: false);
  }
  const keep = <String, List<Object>>{
    'se não me engano paguei 75 de gás no pix': ['expense', 75.0],
    'gastei 42 na lanchonete no débito, se não me engano': ['expense', 42.0],
    'se eu lembro bem, recebi 600 de freela no pix': ['income', 600.0],
    'se não estou enganado o uber deu 23 no pix': ['expense', 23.0],
    'caso você não saiba, paguei 30 de luz no pix': ['expense', 30.0],
    'se eu gastei 45 ontem registra': ['expense', 45.0],
    'se eu não me engano foi 88 na farmácia no crédito à vista': ['expense', 88.0],
    'se a memória não me trai, caiu 1500 de salário no pix': ['income', 1500.0],
    'se liga, gastei 60 no bar no pix': ['expense', 60.0],
    'sei lá se foi caro, mas paguei 220 no tênis no pix': ['expense', 220.0],
    'se bem me lembro comprei um presente de 90 no crédito à vista': ['expense', 90.0],
    'não sei se conta, mas gastei 12 de café no dinheiro': ['expense', 12.0],
    'anota aí se puder: 35 de lanche no pix': ['expense', 35.0],
    'se precisar de mais detalhe me pergunta: paguei 400 de dentista no débito': ['expense', 400.0],
    'caso esteja se perguntando, recebi 300 de reembolso no pix': ['income', 300.0],
    'vê se registra: 70 de gasolina no débito': ['expense', 70.0],
    'confere se tá certo: gastei 33 no pet shop no pix': ['expense', 33.0],
    'mesmo que seja pouco, registra 8 de bala no dinheiro': ['expense', 8.0],
    'se não me falhe, o açougue foi 64 no pix': ['expense', 64.0],
    'se eu paguei 120 de água? paguei sim, no boleto': ['expense', 120.0],
  };
  n = 0;
  keep.forEach((p, v) => add(3, 'keep${++n}', [p], 'grava ${v[0]} ${v[1]}', one(v[0] as String, v[1] as double)));

  // ── Eixo 4: datas ditas ao lançar + recorrência ──
  final dated = <String, List<Object>>{
    'paguei 28 no barbeiro na quinta passada no pix': ['expense', 28.0, backTo(DateTime.thursday)],
    'comprei ração de 90 no sábado no débito': ['expense', 90.0, backTo(DateTime.saturday)],
    'domingo gastei 55 no churrasco no pix': ['expense', 55.0, backTo(DateTime.sunday)],
    'segunda-feira paguei 35 de estacionamento no dinheiro': ['expense', 35.0, backTo(DateTime.monday)],
    'gastei 70 no petshop faz 5 dias no pix': ['expense', 70.0, -5],
    'há dois dias recebi 400 de freela no pix': ['income', 400.0, -2],
    'tem 6 dias que paguei 120 de gás no pix': ['expense', 120.0, -6],
    'gastei 48 na lanchonete em 20/09 no crédito à vista': ['expense', 48.0, ddmm(20, 9)],
    'no dia 14/09 paguei 300 de mecânico no pix': ['expense', 300.0, ddmm(14, 9)],
    'peguei uma jaqueta de 199 dia 21 no pix': ['expense', 199.0, dayN(21)],
    'dia 2 eu paguei 80 de internet no boleto': ['expense', 80.0, dayN(2)],
    'recebi 150 do bico no dia 19 no pix': ['income', 150.0, dayN(19)],
    'paguei 60 na pizzaria sexta à noite no pix': ['expense', 60.0, backTo(DateTime.friday)],
    'gastei 33 de uber quarta de manhã no débito': ['expense', 33.0, backTo(DateTime.wednesday)],
    'gastei 40 no bar no último sábado no pix': ['expense', 40.0, backTo(DateTime.saturday)],
    'anteontem à noite gastei 90 no restaurante no crédito à vista': ['expense', 90.0, -2],
    'ontem de tarde paguei 15 de estacionamento no pix': ['expense', 15.0, -1],
    'gastei 95 na farmácia no dia 1º no débito': ['expense', 95.0, dayN(1)],
    'comprei um vestido de 180 em 12/9 no pix': ['expense', 180.0, ddmm(12, 9)],
    'paguei o encanador, 250, na terça passada no dinheiro': ['expense', 250.0, backTo(DateTime.tuesday)],
    'gastei trinta reais no açougue há quatro dias no pix': ['expense', 30.0, -4],
    'paguei 85 de gás dia 30 no pix': ['expense', 85.0, dayN(30)],
    'recebi 1000 de freela em 5/9 no pix': ['income', 1000.0, ddmm(5, 9)],
    'gastei 20 no mercadinho dia 20 do mês passado no pix': ['expense', 20.0, lastMonthDay(20)],
    'paguei a netflix de 55 dia 12 no crédito à vista': ['expense', 55.0, dayN(12)],
  };
  n = 0;
  dated.forEach((p, v) => add(4, 'date${++n}', [p], '${v[0]} ${v[1]} em ${_dm(_today.add(Duration(days: v[2] as int)))}',
      onceOn(v[0] as String, v[1] as double, v[2] as int)));
  const ask = [
    'fiz uma compra de 300 no atacadão mês passado no débito',
    'paguei 45 no cabeleireiro amanhã no pix',
    'recebi 200 de comissão semana que vem no pix',
    'paguei 75 na oficina na próxima sexta no débito',
    'comprei um fone de 120 no mês passado no pix',
    'comprei vitamina de 50 no mês retrasado no pix',
  ];
  n = 0;
  for (final p in ask) {
    add(4, 'ask${++n}', [p], 'pergunta a data, não grava', asksDate);
  }
  add(4, 'mt1', ['comprei uma panela de 70 no mês passado, no pix', 'no dia 3'], 'despesa 70 em ${_dm(_today.add(Duration(days: lastMonthDay(3))))}',
      onceOn('expense', 70, lastMonthDay(3)));
  add(4, 'mt2', ['paguei 40 no bar amanhã no pix', 'anteontem'], 'despesa 40 anteontem', onceOn('expense', 40, -2));
  add(4, 'mt3', ['o sacolão do mês passado foi 99 no pix', 'foi dia 28'], 'despesa 99 em ${_dm(_today.add(Duration(days: lastMonthDay(28))))}',
      onceOn('expense', 99, lastMonthDay(28)));
  add(4, 'mt4', ['o cliente me pagou 500 amanhã no pix', 'hoje'], 'receita 500 hoje', onceOn('income', 500, 0));
  final rec = <String, List<Object>>{
    'a mensalidade do pilates é 120, todo dia 5 no pix': ['expense', 120.0, 5],
    'minha netflix vence dia 12, 55 no crédito': ['expense', 55.0, 12],
    'todo dia 20 pago 300 da escola de inglês no boleto': ['expense', 300.0, 20],
    'recebo 2500 de salário todo dia 7': ['income', 2500.0, 7],
    'a conta de água vence todo dia 18, uns 95 no boleto': ['expense', 95.0, 18],
    'pago 89 de internet mensal no dia 25 no débito': ['expense', 89.0, 25],
    'o spotify cai dia 3, 21,90 no crédito': ['expense', 21.9, 3],
  };
  n = 0;
  rec.forEach((p, v) => add(4, 'rec${++n}', [p], 'recorrente ${v[0]} ${v[1]} dia ${v[2]}', recurring(v[0] as String, v[1] as double, v[2] as int)));

  // ── Eixo 5: rascunho sem valor ⏎ frase nova completa ──
  final fresh = <List<Object?>>[
    // [rascunho, frase nova, tipo, valor, categorias aceitas, categoria que NÃO pode herdar]
    ['comprei remédio', 'o plano de saúde me reembolsou 250 no pix', 'income', 250.0, null, null],
    ['paguei a conta de gás', 'ganhei 80 de gorjeta no dinheiro', 'income', 80.0, null, null],
    ['gastei no cabeleireiro no pix', 'deixei 45 no estacionamento do shopping no pix', 'expense', 45.0, {'transport'}, null],
    ['comprei uma blusa', 'mandei 200 pra minha poupança pelo pix', 'transfer', 200.0, null, null],
    ['paguei a feira', 'o almoço saiu 38 no débito', 'expense', 38.0, {'leisure'}, 'supermarket'],
    ['comprei ração pro cachorro', 'caíram 900 da bolsa no pix', 'income', 900.0, null, null],
    ['comprei uns remédios na drogaria no débito', 'o sacolão de ontem saiu 150 no débito', 'expense', 150.0, {'supermarket'}, 'health'],
    ['paguei a luz', 'recebi o salário de 3500', 'income', 3500.0, null, null],
    ['comprei gasolina', 'vendi minha bicicleta por 400 no pix', 'income', 400.0, null, null],
    ['tomei umas no boteco no pix', 'meu amigo me pagou 50 no pix', 'income', 50.0, null, null],
    ['paguei a escola do menino', 'gastei 22 de pão no dinheiro', 'expense', 22.0, null, 'education'],
    ['saí pra jantar com a patroa no pix', 'recebi cento e vinte de freela no pix', 'income', 120.0, null, null],
    ['paguei o dentista do menino', 'o táxi deu 36 no pix', 'expense', 36.0, {'transport'}, 'health'],
    ['comprei um livro', 'ganhei 500 de bônus no pix', 'income', 500.0, null, null],
    ['gastei no posto', 'pus 60 de crédito no celular no pix', 'expense', 60.0, null, null],
    ['paguei a taxa do clube', 'pedi uma pizza ontem, 72 no crédito à vista', 'expense', 72.0, {'leisure'}, 'housing'],
    ['gastei no shopping no crédito', 'meu irmão me mandou 100 no pix', 'income', 100.0, null, null],
    ['comprei material de construção', 'paguei 130 de consulta no débito', 'expense', 130.0, {'health'}, null],
  ];
  n = 0;
  for (final f in fresh) {
    add(5, 'new${++n}', [f[0] as String, f[1] as String], '${f[2]} ${f[3]} (frase nova, não funde)',
        one(f[2] as String, f[3] as double,
            cats: f[4] as Set<String>?, notCat: f[5] as String?, catSev: 'P1', day: (f[1] as String).contains('ontem') ? -1 : null));
  }
  const comments = [
    ['gastei no uber', 'que trânsito horrível hoje'],
    ['paguei a dentista da minha filha', 'nossa, tô morto de cansado'],
    ['gastei no petshop', 'hoje o dia foi puxado demais'],
    ['paguei o seguro do carro', 'deixa eu achar o comprovante'],
    ['comprei um presente', 'minha irmã faz aniversário sábado'],
  ];
  n = 0;
  for (final c in comments) {
    add(5, 'cmt${++n}', c, 'comentário não grava nada', nothingSaved, settle: false);
  }
  final answers = <List<Object?>>[
    ['gastei no sacolão no pix', '50', 'expense', 50.0],
    ['paguei a luz no pix', 'deu 230', 'expense', 230.0],
    ['paguei o aluguel da casa da praia', 'foi 1500 no boleto', 'expense', 1500.0],
    ['gastei na padaria', 'uns 18 no dinheiro', 'expense', 18.0],
    ['recebi do freela', '600 no pix', 'income', 600.0],
    ['peguei um uber na volta pro trabalho', 'trinta e dois no pix', 'expense', 32.0],
    ['fiz compra no açougue no débito', 'o açougue deu 95', 'expense', 95.0],
    ['paguei a inscrição da natação', 'R\$ 110,00 no crédito à vista', 'expense', 110.0],
    ['gastei com o veterinário', 'foram 280 no pix', 'expense', 280.0],
    ['comprei um livro', 'saiu por 45 no pix', 'expense', 45.0],
    ['ganhei um bônus', '1200', 'income', 1200.0],
    ['paguei a água', 'custou 88 no boleto', 'expense', 88.0],
    ['gastei no cinema no pix', 'gastei 40 lá', 'expense', 40.0],
    ['recebi o aluguel do quarto', 'caiu 700 no pix', 'income', 700.0],
    ['paguei o gás', 'cento e dez no dinheiro', 'expense', 110.0],
  ];
  n = 0;
  for (final a in answers) {
    final base = one(a[2] as String, a[3] as double);
    add(5, 'ans${++n}', [a[0] as String, a[1] as String], 'resposta: ${a[2]} ${a[3]} (completa o rascunho)', (c) {
      final o = base(c);
      if (o != null) return o;
      // Resposta legítima tratada como frase nova: valor certo, mas o contexto do rascunho se perde.
      if (c.replies.any((r) => r.text.contains('Deixei de lado'))) return _fail('P2', c, 'descartou o rascunho em vez de completá-lo');
      return null;
    });
  }

  // ── Eixo 6: nome × dia da semana (relógio fixo terça 29/09/2026) ──
  final wrong = <List<String?>>[
    // [frase, título que pode ser sugerido, distrator que NÃO pode aparecer]
    ['muda o hortifruti de quinta pra 50', 'Hortifruti', 'Empório'],
    ['o cinema de domingo foi 60', 'Cinema', 'Bar do Zé'],
    ['o táxi de sexta foi no débito', 'Táxi', 'Estacionamento'],
    ['corrige o cinema de anteontem pra 48', 'Cinema', 'Bar do Zé'],
    ['a farmácia do dia 15 foi 30', 'Farmácia', 'Dentista'],
    ['o empório de sábado foi 42', 'Empório', 'Hortifruti'],
    ['altera o bar do zé de sexta pra 70', 'Bar do Zé', 'Cinema'],
    ['troca o pagamento do estacionamento de quarta pro crédito', 'Estacionamento', 'Táxi'],
    ['o dentista de segunda foi 230', 'Dentista', 'Farmácia'],
    ['muda a lanchonete de domingo pra 25', 'Lanchonete', 'Bar do Zé'],
    ['muda o hortifruti do dia 24 pra 47', 'Hortifruti', 'Empório'],
    ['passa o táxi de sábado pra 30', 'Táxi', 'Hortifruti'],
  ];
  n = 0;
  for (final w in wrong) {
    add(6, 'edit${++n}', [w[0]!], 'não muda nada; sugere ${w[1]}', untouched(w[1]!, distractor: w[2]), settle: false, fixed: true);
  }
  add(6, 'noname1', ['muda a lavanderia de sexta pra 20'], 'não muda nada (nome inexistente)', (c) {
    if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou dados sem confirmação');
    return null;
  }, settle: false, fixed: true);
  add(6, 'noname2', ['o açaí de domingo foi 18'], 'não muda o Bar do Zé sem confirmação', (c) {
    if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou dados sem confirmação');
    return null;
  }, settle: false, fixed: true);
  final wrongDel = <List<String?>>[
    ['apaga o táxi de sexta', 'Estacionamento'],
    ['exclui o bar do zé de sábado', 'Hortifruti'],
    ['exclui o lançamento do empório de ontem', 'Farmácia'],
    ['remove o hortifruti do dia 24', 'Empório'],
    ['deleta aquele cinema de domingo', 'Bar do Zé'],
    ['tira o dentista de segunda', 'Farmácia'],
    ['apaga a lavanderia de sexta', 'Cinema'],
    ['some com o estacionamento de quarta', 'Táxi'],
    ['tira a lanchonete de ontem', 'Farmácia'],
  ];
  n = 0;
  for (final d in wrongDel) {
    add(6, 'del${++n}', [d[0]!, 'sim'], 'não apaga nada, nem após "sim"; não oferece ${d[1]}', (c) {
      if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou dados');
      if (c.firstReply.route == 'confirm_delete') return _fail('P0', c, 'pediu confirmação para apagar outro registro');
      if (c.firstReply.text.contains(d[1]!)) return _fail('P2', c, 'citou o distrator');
      return null;
    }, settle: false, fixed: true);
  }
  add(6, 'ok1', ['muda o hortifruti de sábado pra 50'], 'Hortifruti → 50', onlyThis('hort', ok: (t) => t.amount == 50), settle: false, fixed: true);
  add(6, 'ok2', ['o cinema de sexta foi 60'], 'Cinema → 60', onlyThis('cine', ok: (t) => t.amount == 60), settle: false, fixed: true);
  add(6, 'ok3', ['o táxi de quarta foi no débito'], 'Táxi → débito', onlyThis('taxi', ok: (t) => t.paymentMethod == 'debit_card'),
      settle: false, fixed: true);
  add(6, 'ok4', ['apaga o bar do zé de domingo', 'sim'], 'apaga só o Bar do Zé', onlyThis('bar', deleted: true), settle: false, fixed: true);
  add(6, 'ok5', ['exclui o empório de quinta', 'sim'], 'apaga só o Empório', onlyThis('empo', deleted: true), settle: false, fixed: true);
  add(6, 'ok6', ['a farmácia de ontem foi 35'], 'Farmácia → 35', onlyThis('farm', ok: (t) => t.amount == 35), settle: false, fixed: true);
  add(6, 'ok7', ['o dentista do dia 15 foi 230'], 'Dentista → 230', onlyThis('dent', ok: (t) => t.amount == 230), settle: false, fixed: true);
  add(6, 'ok8', ['muda o hortifruti de quinta pra 50', 'muda o de 26/09 pra 50'], 'Hortifruti → 50 pelo caminho sugerido',
      onlyThis('hort', ok: (t) => t.amount == 50), settle: false, fixed: true);
  // "não achei X de <dia>; o mais próximo é X em DD/MM" ⏎ aceite curto.
  add(6, 'sug1', ['muda o hortifruti de quinta pra 50', 'sim'], 'aceita a sugestão: Hortifruti → 50',
      onlyThis('hort', ok: (t) => t.amount == 50), settle: false, fixed: true, feature: true);
  add(6, 'sug2', ['o cinema de domingo foi 60', 'esse'], 'aceita a sugestão: Cinema → 60', onlyThis('cine', ok: (t) => t.amount == 60),
      settle: false, fixed: true, feature: true);
  add(6, 'sug3', ['o táxi de sexta foi no débito', 'pode ser'], 'aceita a sugestão: Táxi → débito',
      onlyThis('taxi', ok: (t) => t.paymentMethod == 'debit_card'), settle: false, fixed: true, feature: true);
  add(6, 'sug4', ['apaga o táxi de sexta', 'esse', 'sim'], 'aceita a sugestão e confirma: apaga só o Táxi', onlyThis('taxi', deleted: true),
      settle: false, fixed: true, feature: true);
  add(6, 'sug5', ['a farmácia do dia 15 foi 30', 'sim'], 'aceita a sugestão: Farmácia → 30', onlyThis('farm', ok: (t) => t.amount == 30),
      settle: false, fixed: true, feature: true);

  // Relógio na quarta 30/09 (hoje do portão): "quarta" = hoje ou a da semana passada; "ontem" = terça.
  add(6, 'wed1', ['pode apagar a lanchonete de ontem', 'sim'], 'apaga só a Lanchonete (29/09 = ontem)', onlyThis('lanch', deleted: true),
      settle: false, fixed: true, clock: _wedNow);
  add(6, 'wed2', ['o táxi de quarta foi 31'], 'só o Táxi (23/09) muda ou é sugerido; nada mais', (c) {
    final o = onlyThis('taxi', ok: (t) => t.amount == 31)(c);
    if (o == null) return null;
    return untouched('Táxi', distractor: 'Lanchonete')(c) == null ? null : o;
  }, settle: false, fixed: true, clock: _wedNow);
  add(6, 'wed3', ['a farmácia de segunda foi 36'], 'Farmácia → 36', onlyThis('farm', ok: (t) => t.amount == 36),
      settle: false, fixed: true, clock: _wedNow);
  add(6, 'wed4', ['muda a farmácia de terça pra 36'], 'não muda nada; sugere Farmácia, não a Lanchonete',
      untouched('Farmácia', distractor: 'Lanchonete'), settle: false, fixed: true, clock: _wedNow);
  add(6, 'wed5', ['remove o cinema de ontem', 'sim'], 'não apaga nada, nem a Lanchonete de ontem', (c) {
    if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou dados');
    if (c.firstReply.route == 'confirm_delete') return _fail('P0', c, 'pediu confirmação para apagar outro registro');
    return null;
  }, settle: false, fixed: true, clock: _wedNow);
  add(6, 'wed6', ['o cinema de quinta foi 58'], 'não muda nada; sugere Cinema, não o Empório', untouched('Cinema', distractor: 'Empório'),
      settle: false, fixed: true, clock: _wedNow);

  return cs;
}

// ─────────────────────────── execução ───────────────────────────

String? _settleAnswer(Sim3 s) {
  if (s.pendingBatch != null) {
    final open = s.pendingBatch!.where((d) => !d.isComplete).expand((d) => d.missingSlots).toSet();
    // Categoria de um item ("pão", "sabonete") não é o objeto do eixo 2: responde "mercado".
    if (open.isNotEmpty && open.every((m) => const {'payment_method', 'installments', 'category'}.contains(m))) {
      return open.contains('payment_method') ? 'pix' : (open.contains('category') ? 'mercado' : 'à vista');
    }
    return null;
  }
  final a = s.active;
  if (a == null || a.isComplete || a.missingSlots.isEmpty) return null;
  const answers = {'payment_method': 'pix', 'installments': 'à vista', 'recurrence_duration': 'sem prazo', 'category': 'outros'};
  if (!a.missingSlots.every(answers.containsKey)) return null;
  return answers[a.missingSlots.first];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  test('ACCA lote A — generalização', () {
    final cases = buildCases();
    final pass = <int, int>{}, total = <int, int>{}, featPass = <int, int>{}, featTotal = <int, int>{};
    final sevCount = <String, int>{};
    print('ACCA_INFO|hoje=${_dm(_today)} weekday=${_today.weekday} casos=${cases.length}');
    for (final k in cases) {
      final repo = FinancialRepository(persistence: _NullPersistence());
      for (final t in repo.transactions.toList()) {
        repo.deleteTransaction(t.id);
      }
      if (k.axis == 6) {
        for (final t in _seed6()) {
          repo.addTransaction(t);
        }
      }
      final sim = Sim3(engine, repo, now: k.fixedClock ? () => (k.clock ?? _fixedNow) : null);
      final before = {for (final t in repo.transactions) t.id: jsonEncode(t.toJson())};
      final turns = <String>[...k.turns];
      final replies = <R3Reply>[];
      String? crash;
      try {
        for (final t in k.turns) {
          replies.add(sim.send(t));
        }
        if (k.settle) {
          for (var i = 0; i < 3; i++) {
            final ans = _settleAnswer(sim);
            if (ans == null) break;
            turns.add('[$ans]');
            replies.add(sim.send(ans));
          }
        }
      } catch (e) {
        crash = '$e';
      }
      final ctx = Ctx(sim, turns, replies, before);
      final o = crash != null ? Outcome('P1', 'EXCEÇÃO: $crash') : k.check(ctx);
      total[k.axis] = (total[k.axis] ?? 0) + 1;
      if (k.feature) featTotal[k.axis] = (featTotal[k.axis] ?? 0) + 1;
      if (o == null) {
        pass[k.axis] = (pass[k.axis] ?? 0) + 1;
        if (k.feature) featPass[k.axis] = (featPass[k.axis] ?? 0) + 1;
        print('ACCA_OK|${k.axis}|${k.id}|${turns.join(' ⏎ ')}|${ctx.summary}');
      } else {
        sevCount[o.sev] = (sevCount[o.sev] ?? 0) + 1;
        print('ACCA_FAIL|${k.axis}|${k.id}|${o.sev}${k.feature ? '(sugestão)' : ''}|${turns.join(' ⏎ ')}|${k.expected}|${o.got}');
      }
    }
    var p = 0, t = 0;
    for (final a in total.keys.toList()..sort()) {
      final ok = pass[a] ?? 0, all = total[a]!;
      p += ok;
      t += all;
      final fOk = featPass[a] ?? 0, fAll = featTotal[a] ?? 0;
      final core = fAll == 0 ? '' : ' | sem fluxo-sugestão: ${ok - fOk}/${all - fAll} (${((ok - fOk) * 100 / (all - fAll)).toStringAsFixed(1)}%)';
      print('ACCA_AXIS|$a|$ok/$all|${(ok * 100 / all).toStringAsFixed(1)}%$core');
    }
    print('ACCA_TOTAL|$p/$t|${(p * 100 / t).toStringAsFixed(1)}%|sev=$sevCount');
  });
}
