// Portão de qualidade do Item 2, lote A (PLANO_CESAR.md) — REVALIDAÇÃO da
// etapa 5 depois das correções 7a + 7b.
//
// Frases INÉDITAS: nenhuma tem Jaccard de tokens ≥ 0,6 com as frases de
// cesar_p0_r3_test, cesar_gate_a_7a_test, cesar_gate_a_7b_test,
// _qa/acceptance_lote_a_probe_test, _qa/chaos_lote_a_test, r1/r2/r3 e holdout
// (conferido por script antes de rodar). Estilos: voz sem pontuação,
// regionalismos, abreviações de WhatsApp, frases longas com ruído, ordem trocada.
//
// Só imprime (nunca falha a suíte):
//   ACCB_FAIL|eixo|id|sev|entrada|esperado|obtido
//   ACCB_OK|eixo|id|entrada|obtido
//   ACCB_AXIS|eixo|passou/total|pct
//   ACCB_TOTAL|passou/total|pct|sev
//
// Rodar:
//   flutter test test/_qa/acceptance_lote_a_r2_probe_test.dart 2>&1 | grep -E "ACCB_"
//
// Cada caso roda num repositório limpo com o `Sim3` (espelho de `_sendMessage`).
// Quando o César só pergunta forma de pagamento / parcelas / prazo (fora do
// objeto do eixo) a sonda responde como o usuário ("pix", "à vista", "sem
// prazo") — esses turnos aparecem entre colchetes. Eixos 1–5: DateTime.now()
// (o motor não aceita relógio). Eixo 6: relógio fixo quarta 30/09/2026 12:00.
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
  final int remindersBefore;
  final List<String?> activeDesc; // descrição do rascunho pendente após cada turno
  Ctx(this.sim, this.turns, this.replies, this.before, this.remindersBefore, this.activeDesc);

  FinancialRepository get repo => sim.repo;
  Map<String, String> get after => {for (final t in repo.transactions) t.id: jsonEncode(t.toJson())};
  List<FinancialTransaction> get added => repo.transactions.where((t) => !before.containsKey(t.id)).toList();
  List<String> get removed => before.keys.where((k) => !after.containsKey(k)).toList();
  List<String> get changed => after.keys.where((k) => before.containsKey(k) && before[k] != after[k]).toList();
  R3Reply get lastReply => replies.last;
  R3Reply get firstReply => replies.first;
  FinancialTransaction? byId(String id) => repo.transactions.where((t) => t.id == id).firstOrNull;
  String get allText => replies.map((r) => r.text).join(' ');

  String get pendingInfo {
    final a = sim.active;
    if (sim.pendingBatch != null) return 'lote pendente(${sim.pendingBatch!.map((d) => '${d.amount}/${d.missingSlots}').join(';')})';
    if (a != null && !a.isComplete) return 'rascunho pendente ${a.intent} ${a.amount} "${a.description}" missing=${a.missingSlots}';
    return '';
  }

  String get summary {
    final add = added.map((t) => '+${t.type.name}:${t.amount}:${t.category}:${t.paymentMethod}:${_dm(t.date)}').join(', ');
    final rem = removed.map((id) => '-$id').join(', ');
    final chg = changed.map((id) {
      final t = byId(id)!;
      return '~$id=${t.amount}:${t.paymentMethod}:${_dm(t.date)}';
    }).join(', ');
    final rems = repo.reminders.length > remindersBefore ? ' lembretes+${repo.reminders.length - remindersBefore}' : '';
    final r = replies.map((r) => r.short).join(' ⏎ ');
    return '{${[add, rem, chg].where((s) => s.isNotEmpty).join(' ')}}$rems $pendingInfo | $r';
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
  Case(this.axis, this.id, this.turns, this.expected, this.check, {this.settle = true, this.fixedClock = false});
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
int ddmm(int d, int m) => _offsetOf(DateTime(_today.year, m, d));
int lastMonthDay(int d) => _offsetOf(DateTime(_today.year, _today.month - 1, d));

bool _sameDay(DateTime a, int offset) {
  final e = DateTime(_today.year, _today.month, _today.day + offset);
  return a.year == e.year && a.month == e.month && a.day == e.day;
}

String _dayLabel(int offset) => _dm(_today.add(Duration(days: offset)));

// ─────────────────────────── verificadores ───────────────────────────

Outcome _fail(String sev, Ctx c, [String note = '']) => Outcome(sev, '${note.isEmpty ? '' : '$note — '}${c.summary}');

bool _askedType(Ctx c) {
  final a = c.sim.active;
  if (a != null && !a.isComplete && a.missingSlots.contains('type')) return true;
  final t = CesarTextLite.fold(c.lastReply.text);
  return t.contains('entrou') && t.contains('saiu');
}

bool _askedDate(Ctx c) {
  final a = c.sim.active;
  if (a != null && !a.isComplete && a.missingSlots.contains('date')) return true;
  if (c.sim.pendingBatch != null && c.sim.pendingBatch!.any((d) => d.missingSlots.contains('date'))) return true;
  return false;
}

/// Exatamente um lançamento novo, do tipo/valor dados; nada editado/apagado.
/// [types] amplia os tipos aceitos; [askTypeOk]/[askDateOk]: perguntar não é falha.
Check one(String type, double amount,
        {Set<String>? types, Set<String>? cats, String? notCat, int? day, bool askTypeOk = false, bool askDateOk = false, String catSev = 'P2'}) =>
    (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
      final a = c.added;
      if (a.isEmpty) {
        if (askTypeOk && _askedType(c)) return null;
        if (askDateOk && _askedDate(c)) return null;
        final miss = c.sim.active?.missingSlots ?? const <String>[];
        final sev = miss.isNotEmpty && miss.every((m) => m == 'type' || m == 'date' || m == 'split') ? 'P2' : 'P1';
        return _fail(sev, c, c.pendingInfo.isNotEmpty ? 'não registrou, ficou perguntando' : 'não registrou');
      }
      if (a.length > 1) return _fail('P0', c, 'registrou ${a.length} lançamentos');
      final t = a.single;
      final okTypes = types ?? {type};
      if (!okTypes.contains(t.type.name)) return _fail('P0', c, 'tipo errado');
      if ((t.amount - amount).abs() > 0.005) return _fail('P0', c, 'valor errado');
      if (day != null && !_sameDay(t.date, day)) return _fail('P0', c, 'data errada (esperado ${_dayLabel(day)})');
      if (notCat != null && t.category == notCat) return _fail('P1', c, 'categoria herdada do rascunho descartado');
      if (cats != null && !cats.contains(t.category)) return _fail(t.category == 'expense_other' ? 'P3' : catSev, c, 'categoria fora de $cats');
      return null;
    };

// Perguntar "entrou ou saiu?" nunca é falha (regra de produto: perguntar em vez de assumir).
Check income(double v, {bool askTypeOk = true}) => one('income', v, askTypeOk: askTypeOk);
Check expense(double v, {bool askTypeOk = true}) => one('expense', v, askTypeOk: askTypeOk);

/// Verbo/direção ambíguos: tem de perguntar "entrou ou saiu?" — gravar qualquer tipo é P0.
Outcome? askType(Ctx c) {
  if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
  if (c.added.isNotEmpty) return _fail('P0', c, 'assumiu a direção (${c.added.first.type.name}) sem perguntar');
  if (_askedType(c)) return null;
  if (c.lastReply.route == 'unknown' && c.lastReply.text.contains('gasto ou uma receita')) {
    return _fail('P2', c, 'pergunta genérica (gasto ou receita?) e perde o valor');
  }
  return _fail('P1', c, 'não perguntou "entrou ou saiu?"');
}

/// Vários lançamentos (valores em qualquer ordem) e tipos por valor.
Check many(List<double> amounts, {List<String>? types}) => (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
      final a = c.added;
      if (a.isEmpty) return _fail('P1', c, c.pendingInfo.isEmpty ? 'não registrou' : 'não registrou, ficou perguntando');
      final got = a.map((t) => t.amount).toList()..sort();
      final exp = [...amounts]..sort();
      final same = got.length == exp.length && List.generate(exp.length, (i) => (got[i] - exp[i]).abs() < 0.005).every((x) => x);
      if (!same) return _fail('P0', c, 'itens ${got.join('+')} ≠ ${exp.join('+')}');
      if (types != null) {
        for (var i = 0; i < amounts.length; i++) {
          if (!a.any((t) => (t.amount - amounts[i]).abs() < 0.005 && t.type.name == types[i])) return _fail('P0', c, 'tipo errado no item ${amounts[i]}');
        }
      } else if (a.any((t) => t.type == TransactionType.income)) {
        return _fail('P0', c, 'item virou receita');
      } else if (a.any((t) => t.type != TransactionType.expense)) {
        // Transferência no lugar de despesa: o saldo fica igual, o rótulo não.
        return _fail('P2', c, 'item virou transferência');
      }
      if (a.any((t) => t.paymentMethod == 'unknown')) return _fail('P2', c, 'item sem forma de pagamento');
      return null;
    };

/// Valor incerto (2 números para um item): não grava; pergunta.
Outcome? noRecordAsks(Ctx c) {
  if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
  if (c.added.isNotEmpty) return _fail('P0', c, 'gravou valor escolhido em silêncio');
  if (c.pendingInfo.isEmpty) return _fail('P2', c, 'não ficou perguntando');
  return null;
}

Outcome? hypothesis(Ctx c) {
  if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'hipótese gravou/alterou dados');
  final r = c.lastReply.route;
  if (r == 'ask' || c.pendingInfo.isNotEmpty) return _fail('P1', c, 'tratou hipótese como lançamento (perguntou slot)');
  if (r == 'unknown') return _fail('P2', c, 'não entendeu a hipótese');
  return null;
}

/// Data futura: não grava lançamento; pergunta a data (lembrete com data futura também serve).
Outcome? futureAsks(Ctx c) {
  if (c.added.isNotEmpty) return _fail('P0', c, 'gravou com data ${_dm(c.added.first.date)} sem perguntar');
  if (_askedDate(c)) return null;
  if (c.repo.reminders.length > c.remindersBefore) return null;
  return _fail('P1', c, 'não perguntou a data');
}

Check recurring(String type, double amount, int due) => (c) {
      final base = one(type, amount)(c);
      if (c.added.isEmpty) return base;
      if (base != null && base.sev == 'P0') return base;
      final d = c.sim.last;
      if (d == null || !d.isRecurrent) return _fail('P0', c, 'virou lançamento único (recorrência perdida)');
      if (d.dueDay != due) return _fail('P0', c, 'dia de vencimento ${d.dueDay} ≠ $due');
      return base;
    };

Check onceOn(String type, double amount, int day, {bool askDateOk = false}) => (c) {
      final base = one(type, amount, day: day, askDateOk: askDateOk)(c);
      if (base != null) return base;
      final d = c.sim.last;
      if (c.added.isNotEmpty && d != null && d.isRecurrent) return _fail('P1', c, 'virou recorrente');
      return null;
    };

Check weekend(String type, double amount) => (c) {
      final base = one(type, amount, day: backTo(DateTime.saturday), askDateOk: true)(c);
      if (base != null) return base;
      if (c.added.isEmpty) return null; // perguntou: aceitável
      final note = c.sim.last?.assumptionNote ?? '';
      if (!note.contains('sábado') && !c.allText.contains('sábado')) return _fail('P2', c, 'gravou no sábado sem avisar');
      return null;
    };

Outcome? nothingSaved(Ctx c) {
  if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'gravou/alterou dados');
  return null;
}

/// Frase nova sem valor com rascunho pendente: nada gravado e o rascunho antigo não absorve a frase.
Outcome? notMerged(Ctx c) {
  final o = nothingSaved(c);
  if (o != null) return o;
  final first = c.activeDesc.first;
  final now = c.activeDesc.last;
  if (c.allText.contains('Deixei de lado')) return null;
  if (now == null || now != first) return null;
  return _fail('P1', c, 'frase nova fundida no rascunho anterior ("$first")');
}

// ── eixo 6 ──
final DateTime _wedNow = DateTime(2026, 9, 30, 12); // quarta (hoje do portão)

FinancialTransaction _tx(String id, String title, double amount, DateTime date, String cat) =>
    FinancialTransaction(id: id, title: title, amount: amount, type: TransactionType.expense, category: cat, paymentMethod: 'pix', date: date);

List<FinancialTransaction> _seed6() => [
      _tx('quit', 'Quitanda', 41, DateTime(2026, 9, 26, 10), 'supermarket'), // sábado
      _tx('acou', 'Açougue', 88, DateTime(2026, 9, 24, 10), 'supermarket'), // quinta
      _tx('teat', 'Teatro', 90, DateTime(2026, 9, 25, 20), 'leisure'), // sexta
      _tx('lava', 'Lava-rápido', 35, DateTime(2026, 9, 25, 10), 'transport'), // sexta
      _tx('past', 'Pastelaria', 23, DateTime(2026, 9, 27, 18), 'leisure'), // domingo
      _tx('drog', 'Drogaria', 47, DateTime(2026, 9, 28, 9), 'health'), // segunda
      _tx('moto', 'Mototáxi', 12, DateTime(2026, 9, 29, 8), 'transport'), // terça (ontem)
      _tx('otic', 'Ótica', 320, DateTime(2026, 9, 15, 14), 'health'), // terça 15/09
      _tx('sorv', 'Sorveteria', 16, DateTime(2026, 9, 30, 10), 'leisure'), // hoje
      _tx('lanseg', 'Lanches Segunda', 30, DateTime(2026, 9, 26, 20), 'leisure'), // sábado (título com dia)
      _tx('cant', 'Cantina Domingo', 55, DateTime(2026, 9, 23, 12), 'leisure'), // quarta 23/09 (título com dia)
    ];

Check untouched(String title, {String? distractor}) => (c) {
      if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou dados sem confirmação');
      if (c.pendingInfo.isNotEmpty) return _fail('P1', c, 'virou lançamento novo pendente');
      if (distractor != null && c.allText.contains(distractor)) return _fail('P2', c, 'ofereceu o distrator $distractor');
      if (!c.allText.contains(title)) return _fail('P2', c, 'não sugeriu $title');
      return null;
    };

Check onlyThis(String id, {bool deleted = false, bool Function(FinancialTransaction t)? ok, bool askOk = false}) => (c) {
      if (c.added.isNotEmpty) return _fail('P0', c, 'criou lançamento novo');
      // "É correção de X ou lançamento novo?" citando o registro certo: perguntar não é falha.
      if (askOk && c.removed.isEmpty && c.changed.isEmpty && c.lastReply.route == 'ask_correction_or_new') return null;
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

/// Nada existente muda (criar lançamento novo é permitido).
Outcome? existingIntact(Ctx c) {
  if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
  return null;
}

/// Pedido de exclusão errado ⏎ "sim": nada apagado e o distrator não é oferecido.
Check noWrongDelete(String distractor) => (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty || c.added.isNotEmpty) return _fail('P0', c, 'mudou dados');
      if (c.firstReply.route == 'confirm_delete') return _fail('P0', c, 'pediu confirmação para apagar outro registro');
      if (c.firstReply.text.contains(distractor)) return _fail('P2', c, 'citou o distrator $distractor');
      return null;
    };

class CesarTextLite {
  static String fold(String s) => s
      .toLowerCase()
      .replaceAll(RegExp('[áàâã]'), 'a')
      .replaceAll(RegExp('[éê]'), 'e')
      .replaceAll('í', 'i')
      .replaceAll(RegExp('[óôõ]'), 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ç', 'c');
}

// ─────────────────────────── casos ───────────────────────────

List<Case> buildCases() {
  final cs = <Case>[];
  void add(int axis, String id, List<String> turns, String exp, Check chk, {bool settle = true, bool fixed = false}) =>
      cs.add(Case(axis, id, turns, exp, chk, settle: settle, fixedClock: fixed));
  var n = 0;

  // ── Eixo 1: direção do dinheiro ──
  const inc = <String, double>{
    'oxe recebi 230 do conserto que fiz pra vizinha': 230,
    'bah ganhei uns 90 pila de gorjeta hj': 90,
    'o moço da oficina me pagou 400 pelo motor velho': 400,
    'minha tia me mandou 150 pra ajudar no aluguel': 150,
    'pingou 520 do auxilio hoje cedo': 520,
    'entrou 1800 referente ao projeto de consultoria': 1800,
    'a loja me estornou 89 da compra cancelada': 89,
    'meu socio repassou 700 da parte dele pra mim': 700,
    'cobrei 120 do meu cliente e ele pagou no pix': 120,
    'o pessoal da vaquinha me devolveu 60': 60,
    'tirei 95 com a venda de uns livros usados': 95,
    'caiu a restituição do imposto de renda 1340': 1340,
    'arrecadei 180 na rifa do time de várzea': 180,
    'lucrei 400 na revenda do celular': 400,
    'faturamos 2300 na feirinha de artesanato': 2300,
    'recebi trezentos e vinte do bico de garçom': 320,
    'vendi meu ps4 pro primo por 1100 tudo no pix': 1100,
    'a firma reembolsou 132 de combustível': 132,
  };
  inc.forEach((p, v) => add(1, 'inc${++n}', [p], 'receita $v', income(v)));
  n = 0;
  const out = <String, double>{
    'me cobraram 45 de taxa de entrega do app': 45,
    'paguei 38 no cabelereiro sô': 38,
    'o mecânico levou 280 pelo serviço do freio': 280,
    'tive que pagar 130 de multa do detran no pix': 130,
    'veio a cobrança de 99 da academia no cartao': 99,
    'descontaram 55 do meu salário por causa do atraso': 55,
    'reembolsei 40 pro meu colega do almoço': 40,
    'o posto cobrou 210 pra encher o tanque': 210,
    'dividimos o rango do boteco e a minha parte deu 48': 48,
    'bancei 90 da pizza da galera': 90,
    'a loja me vendeu um tênis por 260': 260,
    'meti 60 de gasolina na moto': 60,
    'perdi 50 conto na aposta do jogo': 50,
  };
  out.forEach((p, v) => add(1, 'exp${++n}', [p], 'despesa $v (nunca receita)', expense(v)));
  n = 0;
  // "me X" com sentido definido: grava o tipo certo ou pergunta; tipo trocado é P0.
  const meX = <String, List<Object>>{
    'uai o freguês acertou os 250 que devia da marmita': ['income', 250.0],
    'pix de 90 da carla': ['income', 90.0],
    'me tomaram 50 no assalto': ['expense', 50.0],
    'me acertaram 300 da diária': ['income', 300.0],
    'me custou 80 o conserto do chuveiro': ['expense', 80.0],
    'me rendeu 200 o bazar': ['income', 200.0],
    'me passaram 150 por fora': ['income', 150.0],
    'acertei 250 com o síndico': ['expense', 250.0],
  };
  meX.forEach((p, v) => add(1, 'mex${++n}', [p], '${v[0]} ${v[1]} ou pergunta "entrou ou saiu?"', one(v[0] as String, v[1] as double, askTypeOk: true)));
  n = 0;
  const unclear = [
    'zerei 80 com o joão',
    'rolou 120 com o fornecedor',
    'fiz um rolo de 200 com meu primo',
    'movimentei 300 no pix',
    'troquei 100 com o vizinho',
    'mexi 70 com o cartão do meu pai',
  ];
  for (final p in unclear) {
    add(1, 'unc${++n}', [p], 'pergunta "entrou ou saiu?", não grava', askType, settle: false);
  }

  // ── Eixo 2: multi-lançamento e contagem de valores ──
  final multi = <String, List<double>>{
    'padaria 14 açougue 62 sacolão 33 no pix': [14, 62, 33],
    'conta de energia 45 e conta da sabesp 45 quitei as duas no pix': [45, 45],
    'uber ida 18 uber volta 18 no pix': [18, 18],
    'lanche 9,50 | refri 6 no dinheiro': [9.5, 6],
    'coloquei 50 de gasolina daí paguei 12 de estacionamento no pix': [50, 12],
    'no mercado foi 230 e na feira 58 tudo no debito': [230, 58],
    'almoco 32 janta 41 no credito a vista': [32, 41],
    'pedagio 7,80 pedagio 7,80 no dinheiro': [7.8, 7.8],
    'mandei 100 pro dizimo e mais 50 pra oferta no pix': [100, 50],
    'torrei trinta e cinco no hortifruti e mais doze na banca de jornal pix': [35, 12],
    'paguei 89 da net, 120 da luz, ainda 64 do gás, tudo boleto': [89, 120, 64],
    'barbeiro 40 + gorjeta 10 no pix': [40, 10],
    'mds gastei 25 no xerox e 25 na cantina hj no pix': [25, 25],
    'kombi do pastel 15, caldo de cana 8, tudo no dinheiro': [15, 8],
    'pão 7 leite 6 manteiga 12 café 18 no débito': [7, 6, 12, 18],
    'farmácia 27 e depois mercadinho 43 no pix': [27, 43],
  };
  n = 0;
  multi.forEach((p, v) => add(2, 'multi${++n}', [p], '${v.length} despesas ${v.join('+')}', many(v)));
  add(2, 'mix1', ['recebi 300 do freela, paguei 80 de internet no pix'], 'receita 300 + despesa 80', many([300, 80], types: ['income', 'expense']));
  add(2, 'mix2', ['vendi a mesa por 250 e comprei uma cadeira de 90 no pix'], 'receita 250 + despesa 90',
      many([250, 90], types: ['income', 'expense']));
  const single = <String, double>{
    'paguei 35 no x-tudo do trailer da quadra 405 no pix': 35,
    'comprei 2 litros de açaí por 30 no pix': 30,
    'paguei a parcela 3/10 do sofá, 180 no boleto': 180,
    'abasteci o gol g5 1.6 com 150 no débito': 150,
    'paguei 95 do licenciamento da placa QWE-4521 no pix': 95,
    'comprei meio quilo de queijo por 28 no pix': 28,
    'paguei 60 no presente do meu sobrinho de 8 anos no pix': 60,
    'gastei 18 no cinema da sessão das 21h no pix': 18,
    'comprei um samsung a54 por 1600 no crédito em 10x': 1600,
    'paguei 45 no rodízio pra 4 pessoas no pix': 45,
    'comprei 1/2 dúzia de ovos por 9 no dinheiro': 9,
    'paguei 25 de frete pro cep 01310-100 no pix': 25,
    'comprei um iphone 15 pro max de 256gb por 5200 em 12x no crédito': 5200,
    'paguei 120 na consulta do consultório 1102 no pix': 120,
    'tomei 3 cafés e paguei 15 no total no dinheiro': 15,
    'comprei uma lata de tinta de 18 litros por 320 no débito': 320,
    'paguei 40 no corte às 9 e meia no pix': 40,
    'gastei 55 no bolo de 2 andares no pix': 55,
    'comprei 5 pacotes de fralda tamanho G por 210 no pix': 210,
    'paguei 1 real e 50 centavos no chiclete no dinheiro': 1.5,
    'gastei cento e oitenta e sete reais e quarenta centavos no mercado no pix': 187.4,
    'paguei 300 de aluguel do box 12 no shopping no pix': 300,
    'ônibus 4,40 da linha 8012 no dinheiro': 4.4,
  };
  n = 0;
  single.forEach((p, v) => add(2, 'single${++n}', [p], 'UM lançamento de $v (outros números não são valor)', one('expense', v, day: 0)));
  add(2, 'single-sp', ['gastei 70 na rua 25 de março no pix'], 'UM lançamento de 70 hoje (25 de março é endereço) ou pergunta',
      one('expense', 70, day: 0, askDateOk: true));
  add(2, 'range1', ['o mercado deu 80 90 reais sei la no pix'], 'dois números p/ um item: pergunta, não grava', noRecordAsks);
  add(2, 'range2', ['gastei uns 30 a 40 conto no bar no pix'], 'faixa de valor: pergunta, não grava', noRecordAsks);

  // ── Eixo 3: hipóteses × fatos ──
  const hyp = [
    'se eu parcelar a tv de 3500 em 12x como fica meu mes',
    'caso o aluguel suba pra 1600 eu ainda consigo pagar',
    'vale a pena eu pegar um carro de 40 mil se ganho 4500',
    'e se eu cortar o ifood de 400 por mes quanto economizo',
    'se eu gastar 200 no aniversario da minha filha fico no vermelho?',
    'dá pra eu comprar um celular de 1800 se eu parcelar em 6?',
    'se o freela de 900 cair amanhã eu fecho o mes positivo?',
    'caso eu venda o carro por 30 mil quanto fico de saldo',
    'e se eu pagasse 150 a mais na fatura?',
    'suponhamos que a viagem custe 2500, cabe no orçamento',
    'to pensando em comprar uma air fryer de 450, será que rola?',
    'qnt sobra se eu tirar 500 pro condominio',
    'se por acaso eu gastar 70 no bar hoje estoura?',
    'no caso de eu pagar 800 no dentista fico com quanto',
    'quanto eu teria se guardasse 100 por semana',
    'se eu pagar a fatura inteira de 2100 sobra alguma coisa?',
    'caso a minha mae precise de 500 eu consigo mandar?',
    'eu ficaria no azul gastando 350 de roupa?',
    'cogito pagar 90 numa academia nova, compensa?',
    'quero saber se dá pra torrar 250 no rodizio sabado',
  ];
  n = 0;
  for (final h in hyp) {
    add(3, 'hyp${++n}', [h], 'não grava; responde a hipótese', hypothesis, settle: false);
  }
  final facts = <String, Check>{
    'se liga que eu torrei 85 no rodizio no pix': expense(85),
    'nem sei se foi certo mas comprei um tenis de 330 no credito a vista': expense(330),
    'caso alguém pergunte, paguei 150 do condomínio no pix': expense(150),
    'paguei 60 de estacionamento no pix, se é que dá pra acreditar': expense(60),
    'recebi 900 do cliente no pix, caso vc queira anotar': income(900),
    'eu perguntei se aceitava pix e paguei 35 no pix': expense(35),
    'se não fosse o desconto seria 200, mas paguei 160 no débito': one('expense', 160, askTypeOk: false),
    'caso encerrado: devolvi o produto e o estorno de 120 caiu': income(120, askTypeOk: true),
    'minha esposa perguntou se eu tinha pago a luz, paguei sim 180 no pix': expense(180),
    'o cara quis saber se eu vendia o videogame e vendi por 900 no pix': income(900),
    'vi se tinha troco e paguei 20 do lanche no dinheiro': expense(20),
    'se ontem foi caro hoje foi pior: gastei 95 no mercado no pix': one('expense', 95, day: 0),
    'caso do aluguel resolvido, paguei 1300 no boleto': expense(1300),
    'deu 48 o almoço se contar a sobremesa, paguei no débito': expense(48),
    'sei que se eu não anotar esqueço, então gastei 22 de uber no pix': expense(22),
    'se eu fosse você não ia acreditar, mas recebi 2000 de bonus no pix': income(2000),
    'o vendedor falou que se eu pagasse no pix tinha desconto, paguei 270 no pix': expense(270),
    'mesmo se chover amanhã já paguei 50 do ingresso no pix': one('expense', 50, day: 0, askDateOk: true),
    'gastei 33 na lotérica, se eu ganhar te conto': expense(33),
    'comprei 2 pizzas, se não me engano 90 no total, no pix': expense(90),
    'caso queira saber o motivo: gastei 140 com o veterinário da gata no pix': expense(140),
  };
  n = 0;
  facts.forEach((p, chk) => add(3, 'fact${++n}', [p], 'fato: grava (o "se/caso" não é hipótese)', chk));

  // ── Eixo 4: datas ao lançar ──
  final dated = <String, List<Object>>{
    'ontem a noite eu gastei uns 55 no espetinho no pix': ['expense', 55.0, -1, false],
    'antes de ontem paguei 40 no chaveiro no dinheiro': ['expense', 40.0, -2, false],
    'semana passada na terça paguei 80 no eletricista no pix': ['expense', 80.0, backTo(DateTime.tuesday) - 7, true],
    'faz uma semana gastei 120 na feira no débito': ['expense', 120.0, -7, true],
    'recebi 350 da diaria de pedreiro há 10 dias, foi pix': ['income', 350.0, -10, false],
    'gastei 44 no sabado no ifood no pix': ['expense', 44.0, backTo(DateTime.saturday), false],
    'na sexta feira paguei 75 no barzinho no pix': ['expense', 75.0, backTo(DateTime.friday), false],
    'domingão gastei 90 no churras no pix': ['expense', 90.0, backTo(DateTime.sunday), true],
    'paguei 210 do conserto no dia 22 no pix': ['expense', 210.0, dayN(22), false],
    'dia 3 desse mes gastei 50 de farmacia no pix': ['expense', 50.0, dayN(3), false],
    'no dia vinte e cinco paguei 60 de uber no pix': ['expense', 60.0, dayN(25), true],
    'comprei um casaco 150 dia 18/09 no pix': ['expense', 150.0, ddmm(18, 9), false],
    'recebi 400 no dia 1 de setembro no pix': ['income', 400.0, ddmm(1, 9), false],
    'paguei 130 de dentista em 10 de setembro no débito': ['expense', 130.0, ddmm(10, 9), false],
    'gastei 25 no dia 28/8 no pix': ['expense', 25.0, ddmm(28, 8), false],
    'dia 15 do mes passado entrou 700 do bico de garcom no pix': ['income', 700.0, lastMonthDay(15), false],
    'tem uns 3 dias paguei 65 de gás no pix': ['expense', 65.0, -3, true],
    'ante-ontem comprei pão de 8 no dinheiro': ['expense', 8.0, -2, true],
    'hj cedo paguei 12 de café no pix': ['expense', 12.0, 0, false],
    'agora pouco gastei 30 na banca no pix': ['expense', 30.0, 0, false],
    'paguei 55 de luz na segunda no boleto': ['expense', 55.0, backTo(DateTime.monday), false],
    'quinta passada recebi 600 do aluguel do quartinho no pix': ['income', 600.0, backTo(DateTime.thursday), false],
    'tava voltando do trampo ontem e gastei 23 no lanche, pix': ['expense', 23.0, -1, false],
    'oito dias atrás paguei 99 na revisão no débito': ['expense', 99.0, -8, true],
  };
  n = 0;
  dated.forEach((p, v) => add(4, 'date${++n}', [p], '${v[0]} ${v[1]} em ${_dayLabel(v[2] as int)}${v[3] == true ? ' (ou pergunta)' : ''}',
      onceOn(v[0] as String, v[1] as double, v[2] as int, askDateOk: v[3] as bool)));
  const future = [
    'paguei 80 na manicure sexta que vem no pix',
    'gastei 40 de uber depois de amanhã no pix',
    'recebi 250 dia 5/10 no pix',
    'comprei um pneu de 400 semana que vem no débito',
    'paguei 90 no dia 31/10 no pix',
    'recebi 600 amanha cedo no pix',
  ];
  n = 0;
  for (final p in future) {
    add(4, 'fut${++n}', [p], 'data futura: pergunta, não grava', futureAsks);
  }
  add(4, 'wknd1', ['gastei 180 no fim de semana na praia no pix'], 'sábado ${_dayLabel(backTo(DateTime.saturday))} + aviso', weekend('expense', 180));
  add(4, 'wknd2', ['no fds paguei 60 de pizza no pix'], 'sábado + aviso (ou pergunta)', weekend('expense', 60));
  final rec = <String, List<Object>>{
    'todo mês pago 150 da escolinha de futebol do menino dia 10 no pix': ['expense', 150.0, 10],
    'o aluguel de 1400 vence todo dia 5 no boleto': ['expense', 1400.0, 5],
    'recebo mesada de 300 todo dia 15 no pix': ['income', 300.0, 15],
    'mensalmente eu pago 79,90 do plano de internet dia 8 no debito': ['expense', 79.9, 8],
    'todo santo dia 20 cai 1200 da aposentadoria na minha conta': ['income', 1200.0, 20],
  };
  n = 0;
  rec.forEach((p, v) => add(4, 'rec${++n}', [p], 'recorrente ${v[0]} ${v[1]} dia ${v[2]}', recurring(v[0] as String, v[1] as double, v[2] as int)));
  add(4, 'once1', ['paguei 150 da academia no dia 10 no pix'], 'único em ${_dayLabel(dayN(10))}', onceOn('expense', 150, dayN(10)));
  add(4, 'once2', ['comprei 60 de ração dia 2 no pix'], 'único em ${_dayLabel(dayN(2))}', onceOn('expense', 60, dayN(2)));
  add(4, 'mtd1', ['paguei 45 no salão semana que vem no pix', 'foi ontem'], 'pergunta ⏎ grava ontem', onceOn('expense', 45, -1));
  add(4, 'mtd2', ['recebi amanhã 300 da faxina no pix', 'não, foi sexta'], 'pergunta ⏎ grava sexta', onceOn('income', 300, backTo(DateTime.friday)));

  // ── Eixo 5: rascunho pendente ──
  final answers = <List<Object>>[
    ['paguei o mototaxi', '9', 'expense', 9.0],
    ['comprei o gás de cozinha', 'R\$ 125', 'expense', 125.0],
    ['o comprador do sofá me pagou', 'R\$ 600,00 via pix', 'income', 600.0],
    ['paguei a moça da faxina', 'cento e sessenta', 'expense', 160.0],
    ['gastei na lanchonete da faculdade', '17,50', 'expense', 17.5],
    ['paguei o conserto do celular', 'uns 220 no debito', 'expense', 220.0],
    ['almocei no restaurante por quilo', '36 ontem', 'expense', 36.0, -1],
    ['paguei o pedreiro', 'foi 400 na sexta', 'expense', 400.0, backTo(DateTime.friday)],
    ['comprei flores pra minha mãe', 'as flores custaram 70, paguei no pix', 'expense', 70.0],
    ['fiz a feira da semana', '85 reais no dinheiro', 'expense', 85.0],
    ['caiu o aluguel da vaga de garagem', '350', 'income', 350.0],
    ['paguei o conserto da geladeira', 'foi 280 anteontem no pix', 'expense', 280.0, -2],
    ['gastei de uber moto', 'R\$ 23,75', 'expense', 23.75],
    ['paguei o seguro da moto', 'mil e cem no boleto', 'expense', 1100.0],
    ['comprei o presente de casamento da prima', '250 no cartão de crédito', 'expense', 250.0],
    ['comprei o ingresso do show', 'R\$ 180 no débito', 'expense', 180.0],
    ['paguei o guincho', 'quatrocentos e cinquenta no pix', 'expense', 450.0],
    ['paguei a lavanderia', '40 ou 45', '45', 'expense', 45.0],
  ];
  n = 0;
  for (final a in answers) {
    final turns = a.whereType<String>().where((s) => s != 'expense' && s != 'income').toList();
    final type = a.contains('income') ? 'income' : 'expense';
    final value = a.whereType<double>().first;
    final day = a.whereType<int>().firstOrNull;
    final base = one(type, value, day: day);
    add(5, 'ans${++n}', turns, 'resposta: $type $value${day != null ? ' em ${_dayLabel(day)}' : ''} (completa o rascunho)', (c) {
      final o = base(c);
      if (o != null) return o;
      if (c.allText.contains('Deixei de lado')) return _fail('P2', c, 'descartou o rascunho em vez de completá-lo');
      return null;
    });
  }
  const twoNumbers = [
    ['paguei o reboque', '300 ou 350'],
    ['gastei no salão de beleza', 'entre 90 e 110'],
    ['paguei a costureira', 'acho q 40 ou 45 nao lembro'],
    ['comprei material escolar', '120 130 por ai'],
  ];
  n = 0;
  for (final t in twoNumbers) {
    add(5, 'two${++n}', t, 'dois valores na resposta: pergunta qual, não grava', noRecordAsks, settle: false);
  }
  final fresh = <List<Object?>>[
    ['paguei a conta do celular', 'recebi 500 do meu tio no pix', 'income', 500.0, null, null],
    ['comprei uma chuteira', 'o uber pra casa deu 26 no pix', 'expense', 26.0, {'transport'}, null],
    ['comprei verdura na feira', 'vendi minha guitarra por 1200 no pix', 'income', 1200.0, null, null],
    ['paguei o marceneiro', 'tomei um açaí de 15 no pix', 'expense', 15.0, null, null],
    ['comprei xarope pra tosse', 'meu chefe pagou a comissão de 700 no pix', 'income', 700.0, null, null],
    ['paguei o curso de inglês', 'coloquei 50 de crédito no bilhete único no pix', 'expense', 50.0, null, 'education'],
    ['fiz compra no atacarejo', 'paguei 90 de pilates no débito', 'expense', 90.0, null, 'supermarket'],
  ];
  n = 0;
  for (final f in fresh) {
    add(5, 'new${++n}', [f[0] as String, f[1] as String], '${f[2]} ${f[3]} (frase nova, não funde)',
        one(f[2] as String, f[3] as double, cats: f[4] as Set<String>?, notCat: f[5] as String?, catSev: 'P1'));
  }
  const freshNoValue = [
    ['paguei a fatura da energia', 'comprei um sorvete'],
    ['gastei no supermercado do bairro', 'minha irmã me mandou um pix'],
    ['paguei o ifood', 'recebi o décimo terceiro'],
    ['enchi o tanque do carro', 'paguei o estacionamento do shopping'],
    ['paguei o bombeiro hidráulico', 'vendi umas roupas no brechó'],
  ];
  n = 0;
  for (final t in freshNoValue) {
    add(5, 'nov${++n}', t, 'frase nova sem valor: não responde a pergunta anterior', notMerged, settle: false);
  }
  const offTopic = [
    ['paguei o frete', 'quanto já foi de gasto em setembro?'],
    ['comprei um brinquedo', 'esquece isso aí'],
    ['gastei na barbearia', 'rapaz que calor da peste hoje'],
    ['paguei o conserto', 'tenho 3 filhos pra criar'],
    ['comprei cerveja', 'moro no 402'],
    ['paguei o técnico da máquina de lavar', 'ele chegou às 14h'],
    ['gastei na padoca da esquina', 'a fila tava com umas 20 pessoas'],
  ];
  n = 0;
  for (final t in offTopic) {
    // settle: se o César tomou o número como valor, a resposta "pix" do usuário gravaria.
    add(5, 'off${++n}', t, 'outro assunto / número que não é valor: não grava', nothingSaved);
  }

  // ── Eixo 6: referência nome × data (relógio: quarta 30/09/2026) ──
  final edits = <List<Object>>[
    ['o teatro de sexta na real foi 95', 'teat', 'a', 95.0],
    ['altera a quitanda de sábado para 44', 'quit', 'a', 44.0],
    ['bota a drogaria de segunda como 52', 'drog', 'a', 52.0],
    ['o mototaxi de ontem foi 14', 'moto', 'a', 14.0],
    ['a pastelaria de domingo foi no débito', 'past', 'p', 'debit_card'],
    ['passa a ótica pra 300', 'otic', 'a', 300.0],
    ['passa o açougue de quinta pra 92', 'acou', 'a', 92.0],
    ['muda o valor da sorveteria de hoje pra 18', 'sorv', 'a', 18.0],
    ['a otica do dia 15 foi 310', 'otic', 'a', 310.0],
    ['corrige o lava-rapido de sexta pra 40', 'lava', 'a', 40.0],
    ['o lanches segunda foi 33', 'lanseg', 'a', 33.0],
    ['muda a cantina domingo pra 58', 'cant', 'a', 58.0],
    ['ô césar muda aí o açougue da quinta que foi 86 na verdade', 'acou', 'a', 86.0],
    ['o valor certo da ótica é 330', 'otic', 'a', 330.0],
    ['a lanches segunda de sábado foi 31', 'lanseg', 'a', 31.0],
    ['o teatro de 25/09 foi no débito', 'teat', 'p', 'debit_card'],
  ];
  n = 0;
  for (final e in edits) {
    final f = e[2] == 'a' ? (FinancialTransaction t) => t.amount == e[3] : (FinancialTransaction t) => t.paymentMethod == e[3];
    add(6, 'edit${++n}', [e[0] as String], '${e[1]} → ${e[3]}', onlyThis(e[1] as String, ok: f, askOk: true), settle: false, fixed: true);
  }
  final dels = <List<String>>[
    ['pode excluir a pastelaria de domingo', 'sim', 'past'],
    ['tira o mototáxi de terça', 'sim', 'moto'],
    ['exclui o lanches segunda', 'sim', 'lanseg'],
    ['apaga a cantina domingo', 'sim', 'cant'],
    ['joga no lixo o lava-rápido de sexta', 'pode apagar', 'lava'],
  ];
  n = 0;
  for (final d in dels) {
    add(6, 'del${++n}', [d[0], d[1]], 'apaga só ${d[2]} após confirmar', onlyThis(d[2], deleted: true), settle: false, fixed: true);
  }
  final wrong = <List<String?>>[
    ['troca o valor da quitanda de sexta para 44', 'Quitanda', 'Teatro'],
    ['o teatro de sábado foi 95', 'Teatro', 'Quitanda'],
    ['a drogaria de domingo foi 50', 'Drogaria', 'Pastelaria'],
    ['o açougue de sexta foi 90', 'Açougue', 'Teatro'],
    ['o mototaxi de segunda foi 14', 'Mototáxi', 'Drogaria'],
    ['a ótica do dia 20 foi 300', 'Ótica', null],
    ['corrige a pastelaria de sábado pra 25', 'Pastelaria', 'Quitanda'],
  ];
  n = 0;
  for (final w in wrong) {
    add(6, 'wrong${++n}', [w[0]!], 'não muda; sugere ${w[1]}${w[2] != null ? ', não ${w[2]}' : ''}', untouched(w[1]!, distractor: w[2]),
        settle: false, fixed: true);
  }
  add(6, 'sug1', ['a quitanda de sexta foi 44', 'sim'], 'sugestão aceita: quit → 44', onlyThis('quit', ok: (t) => t.amount == 44), settle: false, fixed: true);
  add(6, 'sug2', ['o teatro de sábado foi 95', 'esse'], 'sugestão aceita: teat → 95', onlyThis('teat', ok: (t) => t.amount == 95), settle: false, fixed: true);
  add(6, 'sug3', ['a drogaria de domingo foi no débito', 'pode ser'], 'sugestão aceita: drog → débito',
      onlyThis('drog', ok: (t) => t.paymentMethod == 'debit_card'), settle: false, fixed: true);
  add(6, 'sug4', ['o açougue de sexta foi 90', 'isso'], 'sugestão aceita: acou → 90', onlyThis('acou', ok: (t) => t.amount == 90), settle: false, fixed: true);
  add(6, 'sug5', ['apaga aquele mototaxi da segunda', 'esse', 'sim'], 'sugestão + confirmação: apaga só moto', onlyThis('moto', deleted: true),
      settle: false, fixed: true);
  add(6, 'sug6', ['exclui o teatro de sábado', 'sim', 'sim'], 'sugestão + confirmação: apaga só teat', onlyThis('teat', deleted: true),
      settle: false, fixed: true);
  add(6, 'sug7', ['o mototáxi de segunda foi 14', 'não'], 'recusa a sugestão: nada muda', (c) {
    if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou dados após "não"');
    return null;
  }, settle: false, fixed: true);
  final wrongDel = <List<String>>[
    ['some com o açougue de ontem', 'sim', 'Mototáxi'],
    ['remove a drogaria de sábado', 'sim', 'Quitanda'],
    ['deleta o posto de sexta', 'sim', 'Teatro'],
    ['exclui aí a sorveteria de ontem', 'sim', 'Mototáxi'],
  ];
  n = 0;
  for (final d in wrongDel) {
    add(6, 'wdel${++n}', [d[0], d[1]], 'não apaga nada nem após "sim"; não oferece ${d[2]}', noWrongDelete(d[2]), settle: false, fixed: true);
  }
  add(6, 'none1', ['a padaria de ontem foi 20'], 'não mexe em registro existente', existingIntact, settle: false, fixed: true);
  add(6, 'none2', ['corrige pra 100 a academia da sexta'], 'não mexe em registro existente', existingIntact, settle: false, fixed: true);
  add(6, 'none3', ['passa 50 pra minha mãe'], '"passa N pra pessoa" não edita nada', existingIntact, settle: false, fixed: true);

  return cs;
}

// ─────────────────────────── execução ───────────────────────────

String? _settleAnswer(Sim3 s) {
  if (s.pendingBatch != null) {
    final open = s.pendingBatch!.where((d) => !d.isComplete).expand((d) => d.missingSlots).toSet();
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

  test('ACCB lote A r2 — revalidação', () {
    final cases = buildCases();
    final pass = <int, int>{}, total = <int, int>{};
    final sevCount = <String, int>{};
    print('ACCB_INFO|hoje=${_dm(_today)} weekday=${_today.weekday} casos=${cases.length}');
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
      final sim = Sim3(engine, repo, now: k.fixedClock ? () => _wedNow : null);
      final before = {for (final t in repo.transactions) t.id: jsonEncode(t.toJson())};
      final remBefore = repo.reminders.length;
      final turns = <String>[...k.turns];
      final replies = <R3Reply>[];
      final activeDesc = <String?>[];
      String? crash;
      try {
        for (final t in k.turns) {
          replies.add(sim.send(t));
          final a = sim.active;
          activeDesc.add(a != null && !a.isComplete ? a.description : null);
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
      final ctx = Ctx(sim, turns, replies, before, remBefore, activeDesc);
      final o = crash != null ? Outcome('P1', 'EXCEÇÃO: $crash') : k.check(ctx);
      total[k.axis] = (total[k.axis] ?? 0) + 1;
      if (o == null) {
        pass[k.axis] = (pass[k.axis] ?? 0) + 1;
        print('ACCB_OK|${k.axis}|${k.id}|${turns.join(' ⏎ ')}|${ctx.summary}');
      } else {
        sevCount[o.sev] = (sevCount[o.sev] ?? 0) + 1;
        print('ACCB_FAIL|${k.axis}|${k.id}|${o.sev}|${turns.join(' ⏎ ')}|${k.expected}|${o.got}');
      }
    }
    var p = 0, t = 0;
    for (final a in total.keys.toList()..sort()) {
      final ok = pass[a] ?? 0, all = total[a]!;
      p += ok;
      t += all;
      print('ACCB_AXIS|$a|$ok/$all|${(ok * 100 / all).toStringAsFixed(1)}%');
    }
    print('ACCB_TOTAL|$p/$t|${(p * 100 / t).toStringAsFixed(1)}%|sev=$sevCount');
  });
}
