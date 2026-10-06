// Bateria de QA de conversação do César — RODADA 3 (generalização real).
//
// As baterias r1 (conversation_probe_test.dart) e r2 (conversation_r2_probe_test.dart)
// estão saturadas (100%). Esta usa SÓ frases inéditas — nenhuma repete nem
// parafraseia de perto r1, r2 ou holdout_probe_test.dart — para medir quanto
// das correções generaliza.
//
// NÃO é teste de regressão: não usa `expect`, nunca falha a suíte. Imprime as
// divergências (R3FAIL), um placar por eixo (R3AXIS), o total (R3TOTAL) e, à
// parte, a linha de base de funcionalidades que ainda não existem (R3FUT /
// R3FUTURE — fora do total principal). Achados em docs/qa/findings-conversa-r3.md.
//
// Rodar:  flutter test test/_qa/conversation_r3_probe_test.dart 2>&1 | grep -E "R3FAIL|R3AXIS|R3TOTAL|R3FUT"
//
// Datas: tudo é semeado relativo a DateTime.now(); totais esperados são
// calculados a partir do próprio repositório (mês corrente), então o resultado
// não muda conforme o dia do mês em que a bateria roda. Referências por dia da
// semana ("a feira de segunda") calculam o dia com a mesma regra do resolvedor:
// a última ocorrência daquele dia, 1 a 7 dias atrás.
//
// Reusa o `ChatSim` da bateria r1 (espelha `_sendMessage` do chat, com o
// `CesarAssistant` real e um `FinancialRepository` de verdade).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_probe_test.dart' show ChatSim, Reply;

// ─────────────────────────── modelos de caso ───────────────────────────

class Tx {
  final String axis;
  final String phrase;
  final Set<String>? intent;
  final double? amount;
  final Set<String>? cat;
  final String? pay;
  final int? inst;
  final int? day;
  final bool? recurrent;
  Tx(this.axis, this.phrase, {Object? i, this.amount, Object? cat, this.pay, this.inst, this.day, this.recurrent})
      : intent = i == null ? null : (i is String ? {i} : (i as Set<String>)),
        cat = cat == null ? null : (cat is String ? {cat} : (cat as Set<String>));
}

typedef Setup = void Function(FinancialRepository repo);

class Scn {
  final String axis;
  final String name;
  final List<String> turns;
  final String expected;
  final String? Function(ChatSim s, List<Reply> r) check;
  final Setup? setup;
  Scn(this.axis, this.name, this.turns, this.expected, this.check, {this.setup});
}

// ─────────────────────────── datas e formatação ───────────────────────────

final DateTime _now = DateTime.now();

DateTime _day(int back) => DateTime(_now.year, _now.month, _now.day - back, 12);

/// Dias atrás até a última ocorrência de [weekday] (1=seg … 7=dom), no mínimo [min].
/// Com min=1 é exatamente a regra do `TransactionReferenceResolver`.
int backTo(int weekday, {int min = 1}) {
  var d = (_now.weekday - weekday) % 7;
  while (d < min) {
    d += 7;
  }
  return d;
}

const _monthNames = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
const _weekdayNames = ['segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'];
String get thisMonthName => _monthNames[_now.month - 1];
String get lastMonthName => _monthNames[(_now.month + 10) % 12];

/// 1234.5 → "1.234,50" (formato que o César usa).
String brl(double v) {
  final neg = v < 0;
  final cents = (v.abs() * 100).round();
  final s = (cents ~/ 100).toString();
  final b = StringBuffer();
  for (var k = 0; k < s.length; k++) {
    if (k > 0 && (s.length - k) % 3 == 0) b.write('.');
    b.write(s[k]);
  }
  return '${neg ? '-' : ''}$b,${(cents % 100).toString().padLeft(2, '0')}';
}

bool _thisMonth(DateTime d) => d.year == _now.year && d.month == _now.month;

double monthExp(ChatSim s, [bool Function(FinancialTransaction t)? pred]) => s.repo.transactions
    .where((t) => t.type == TransactionType.expense && _thisMonth(t.date) && (pred == null || pred(t)))
    .fold(0.0, (a, t) => a + t.amount);
double monthInc(ChatSim s) =>
    s.repo.transactions.where((t) => t.type == TransactionType.income && _thisMonth(t.date)).fold(0.0, (a, t) => a + t.amount);
double allBalance(ChatSim s) => s.repo.transactions.fold(0.0, (a, t) => a + (t.type == TransactionType.income ? t.amount : -t.amount));
bool titled(FinancialTransaction t, String sub) => t.title.toLowerCase().contains(sub);

// ─────────────────────────── seeds ───────────────────────────

/// Estado de cada lançamento no início do cenário (para detectar edição/exclusão no alvo errado).
Map<String, String> _snapshot = {};

FinancialTransaction _t(String id, String title, double amount, DateTime date, String cat, String pay,
        {TransactionType type = TransactionType.expense}) =>
    FinancialTransaction(id: 'r3-$id', title: title, amount: amount, type: type, category: cat, paymentMethod: pay, date: date);

/// Conjunto A: gastos recentes variados + mês passado. Somam-se aos dados de demonstração.
void seedA(FinancialRepository repo) {
  repo.addTransaction(_t('ifood1', 'iFood', 41.50, _day(0), 'leisure', 'pix'));
  repo.addTransaction(_t('posto', 'Posto Shell', 189, _day(1), 'transport', 'debit_card'));
  repo.addTransaction(_t('farm', 'Farmácia Pague Menos', 57.80, _day(2), 'health', 'debit_card'));
  repo.addTransaction(_t('acougue', 'Açougue Boi Gordo', 112, _day(3), 'supermarket', 'pix'));
  repo.addTransaction(_t('gas', 'Gás Liquigás', 125, _day(4), 'housing', 'cash'));
  repo.addTransaction(_t('ifood2', 'iFood', 73.90, _day(5), 'leisure', 'credit_card'));
  repo.addTransaction(_t('cinema', 'Cinemark', 64, _day(6), 'leisure', 'credit_card'));
  repo.addTransaction(_t('luzant', 'Conta de luz', 176.40, DateTime(_now.year, _now.month - 1, 12, 12), 'housing', 'bank_slip'));
  repo.addTransaction(_t('mercant', 'Mercado Extra', 512.30, DateTime(_now.year, _now.month - 1, 20, 12), 'supermarket', 'debit_card'));
}

/// Feira na última segunda (hoje, 2026-09-29 terça: ONTEM) + padaria no mesmo dia + outra feira na sexta.
void seedMonYest(FinancialRepository repo) {
  repo.addTransaction(_t('feiraseg', 'Feira livre', 52, _day(backTo(DateTime.monday)), 'supermarket', 'cash'));
  repo.addTransaction(_t('padseg', 'Padaria Pão Nosso', 14, _day(backTo(DateTime.monday)), 'supermarket', 'pix'));
  repo.addTransaction(_t('feirasex', 'Feira livre', 47, _day(backTo(DateTime.friday)), 'supermarket', 'cash'));
}

/// Feira numa segunda de 2+ dias atrás (hoje: 8 dias) + outra feira mais recente no sábado.
void seedMonOld(FinancialRepository repo) {
  repo.addTransaction(_t('feiraseg2', 'Feira livre', 66, _day(backTo(DateTime.monday, min: 2)), 'supermarket', 'cash'));
  repo.addTransaction(_t('feirasab', 'Feira livre', 39, _day(backTo(DateTime.saturday, min: 2)), 'supermarket', 'cash'));
}

/// Só existe feira na quinta — "a feira de segunda" NÃO bate com nada.
void seedNoMatch(FinancialRepository repo) {
  repo.addTransaction(_t('feiraqui', 'Feira livre', 49, _day(backTo(DateTime.thursday)), 'supermarket', 'cash'));
}

/// Cinema no último sábado.
void seedSat(FinancialRepository repo) {
  repo.addTransaction(_t('cinesab', 'Cinemark', 58, _day(backTo(DateTime.saturday)), 'leisure', 'credit_card'));
}

/// Sem dado nenhum (nem demonstração, nem lembretes).
void seedEmpty(FinancialRepository repo) {
  for (final t in [...repo.transactions]) {
    repo.deleteTransaction(t.id);
  }
  for (final r in [...repo.reminders]) {
    repo.removeReminder(r.id);
  }
}

// ─────────────────────────── helpers de verificação ───────────────────────────

List<FinancialTransaction> mine(ChatSim s) =>
    s.repo.transactions.where((t) => !t.id.startsWith('init-') && !t.id.startsWith('r3-')).toList();

FinancialTransaction? tx(ChatSim s, String id) {
  for (final t in s.repo.transactions) {
    if (t.id == id) return t;
  }
  return null;
}

String fmt(FinancialTransaction t) =>
    '${t.title} ${t.amount} ${t.category} ${t.paymentMethod} ${t.type.name} inst=${t.installments} rec=${t.isRecurrent} due=${t.dueDay} ${t.date.day}/${t.date.month}';
String dumpMine(ChatSim s) => 'novos: [${mine(s).map(fmt).join(' ; ')}]';
String dumpId(ChatSim s, String id) => tx(s, id) == null ? '$id APAGADO' : '$id: ${fmt(tx(s, id)!)}';
String full(Reply r) {
  final t = r.text.replaceAll('\n', ' ');
  return '[${r.route}] "${t.length > 380 ? '${t.substring(0, 380)}…' : t}"';
}

/// Lançamentos pré-existentes que mudaram ou sumiram, fora de [except].
List<String> collateral(ChatSim s, Set<String> except) {
  final out = <String>[];
  for (final e in _snapshot.entries) {
    if (except.contains(e.key)) continue;
    final t = tx(s, e.key);
    if (t == null) {
      out.add('${e.key} apagado indevidamente');
    } else if (fmt(t) != e.value) {
      out.add('${e.key} alterado indevidamente: ${fmt(t)}');
    }
  }
  return out;
}

/// Edição por referência: [id] satisfaz [ok], nada novo criado, nada mais mexido.
String? edited(ChatSim s, List<Reply> r, String id, bool Function(FinancialTransaction t) ok) {
  if (mine(s).isNotEmpty) return 'criou lançamento novo em vez de editar: ${dumpMine(s)} / ${dumpId(s, id)} / último: ${full(r.last)}';
  final t = tx(s, id);
  if (t == null) return '$id APAGADO / último: ${full(r.last)}';
  final side = collateral(s, {id});
  if (side.isNotEmpty) return side.join('; ');
  return ok(t) ? null : '${dumpId(s, id)} / último: ${full(r.last)}';
}

/// Exclusão: o turno [turn] pede confirmação; no fim só [gone] sumiu.
String? deleted(ChatSim s, List<Reply> r, int turn, Set<String> gone) {
  if (r.length <= turn || r[turn].route != 'confirm_delete') {
    return 'não pediu confirmação no turno ${turn + 1}: ${r.length > turn ? full(r[turn]) : '-'}';
  }
  if (mine(s).isNotEmpty) return 'criou lançamento: ${dumpMine(s)}';
  final bad = [for (final id in gone) if (tx(s, id) != null) '$id NÃO apagado', ...collateral(s, gone)];
  return bad.isEmpty ? null : '${bad.join('; ')} / confirmação: ${full(r[turn])}';
}

/// Nada mudou nem foi criado.
String? untouched(ChatSim s, List<Reply> r) {
  final bad = [...collateral(s, {}), if (mine(s).isNotEmpty) dumpMine(s)];
  return bad.isEmpty ? null : '${bad.join('; ')} / respostas: ${r.map(full).join(' | ')}';
}

/// Resposta a pergunta: nada salvo, rota aceita, contém ao menos um de [anyOf].
String? answer(ChatSim s, Reply r, bool Function(String route) routeOk, [List<String> anyOf = const []]) {
  if (mine(s).isNotEmpty) return 'salvou lançamento: ${dumpMine(s)} / ${full(r)}';
  final side = collateral(s, {});
  if (side.isNotEmpty) return side.join('; ');
  if (!routeOk(r.route)) return 'rota errada: ${full(r)}';
  if (r.text.contains('Não consegui identificar')) return 'não entendeu: ${full(r)}';
  if (anyOf.isNotEmpty && !anyOf.any(r.text.contains)) return 'faltou um de $anyOf em ${full(r)}';
  return null;
}

bool isReport(String r) => r.startsWith('report:') && r != 'report:unknown';
bool spending(String r) => r == 'report:spending';
bool overview(String r) => r == 'report:overview';
bool anyAnswer(String r) => !['saved', 'multi', 'ask', 'ask_multi', 'unknown', 'unanswered', 'query'].contains(r);

/// Os lançamentos criados têm exatamente estes valores (em qualquer ordem).
String? amounts(ChatSim s, List<double> exp, [bool Function(List<FinancialTransaction> m)? extra]) {
  final got = mine(s).map((t) => t.amount).toList()..sort();
  final want = [...exp]..sort();
  final same = got.length == want.length && [for (var i = 0; i < got.length; i++) (got[i] - want[i]).abs() < 0.001].every((b) => b);
  if (!same || (extra != null && !extra(mine(s)))) return dumpMine(s);
  return null;
}

String? only(ChatSim s, bool Function(List<FinancialTransaction> m) ok) => ok(mine(s)) ? null : dumpMine(s);

String? chain(List<String? Function()> checks) {
  for (final c in checks) {
    final p = c();
    if (p != null) return p;
  }
  return null;
}

// ─────────────────────────── 1 turno: gíria, voz, digitação ───────────────────────────

final txCases = <Tx>[
  // ── gíria / informal ──
  Tx('giria', 'vacilei e gastei 70 conto em skin de joguinho no pix', i: 'expense', amount: 70, pay: 'pix'),
  Tx('giria', 'derreti 180 no rodízio de sushi, cartão de crédito à vista', i: 'expense', amount: 180, cat: 'leisure', pay: 'credit_card'),
  Tx('giria', 'soltei 25 pro cara do lava rápido em espécie', i: 'expense', amount: 25, pay: 'cash'),
  Tx('giria', 'pingou 320 do freela na conta', i: 'income', amount: 320),
  Tx('giria', 'o rango de hoje saiu 34 no débito', i: 'expense', amount: 34, cat: 'leisure', pay: 'debit_card'),
  Tx('giria', 'catei um uber de 21 conto no pix', i: 'expense', amount: 21, cat: 'transport', pay: 'pix'),
  Tx('giria', 'fui de busão, 4,40 no cartão de débito', i: 'expense', amount: 4.40, cat: 'transport', pay: 'debit_card'),
  Tx('giria', 'entrou 2300 do salário hoje', i: 'income', amount: 2300, cat: 'salary'),
  Tx('giria', 'larguei 60 pila na padoca no débito', i: 'expense', amount: 60, pay: 'debit_card'),
  Tx('giria', 'queimei 45 no happy hour ontem no pix', i: 'expense', amount: 45, cat: 'leisure', pay: 'pix', day: -1),
  Tx('giria', 'gastei os tubos na black friday, 1200 no cartão em 6x', i: 'expense', amount: 1200, pay: 'credit_card', inst: 6),
  Tx('giria', 'meu sogro me descolou 200 no pix', i: 'income', amount: 200, pay: 'pix'),
  Tx('giria', 'paguei 16 de pedágio no dinheirinho', i: 'expense', amount: 16, cat: 'transport', pay: 'cash'),
  Tx('giria', 'bati o carro e o funileiro me cobrou 900 no pix', i: 'expense', amount: 900, cat: 'transport', pay: 'pix'),
  Tx('giria', 'fiz uma graninha de 400 com uns bicos de eletricista', i: 'income', amount: 400),
  Tx('giria', 'saiu 99 da minha conta pro plano do celular no débito', i: 'expense', amount: 99, pay: 'debit_card'),
  Tx('giria', 'foi 12 conto o pão com mortadela no pix', i: 'expense', amount: 12, pay: 'pix'),
  Tx('giria', 'comprei umas brusinha na shein, 140 no crédito à vista', i: 'expense', amount: 140, pay: 'credit_card'),
  Tx('giria', 'rolou uma pizza de 58 no delivery no pix', i: 'expense', amount: 58, cat: 'leisure', pay: 'pix'),
  Tx('giria', 'peguei o mototáxi, 8 reais no dinheiro', i: 'expense', amount: 8, cat: 'transport', pay: 'cash'),
  Tx('giria', 'caiu 750 da rescisão', i: 'income', amount: 750),
  Tx('giria', 'o boy do ifood trouxe o lanche, 39 no crédito à vista', i: 'expense', amount: 39, cat: 'leisure', pay: 'credit_card'),
  Tx('giria', 'meti a mão no bolso e paguei 250 no dentista no débito', i: 'expense', amount: 250, cat: 'health', pay: 'debit_card'),
  Tx('giria', 'recebi uma bolada de 5 mil da venda do carro', i: 'income', amount: 5000),
  Tx('giria', 'gastei 15 mangos no açaí no pix', i: 'expense', amount: 15, pay: 'pix'),
  Tx('giria', 'minha tia mandou 150 de presente de aniversário no pix', i: 'income', amount: 150, pay: 'pix'),
  Tx('giria', 'tive que desembolsar 85 no chaveiro em dinheiro', i: 'expense', amount: 85, pay: 'cash'),
  Tx('giria', 'foram 230 na conta de luz, paguei no app do banco no pix', i: 'expense', amount: 230, cat: 'housing', pay: 'pix'),
  Tx('giria', 'cortei o cabelo, 40 no pix', i: 'expense', amount: 40, pay: 'pix'),
  Tx('giria', 'ganhei 90 de gorjeta no trampo', i: 'income', amount: 90),
  Tx('giria', 'a parada do combustível deu 260 no débito', i: 'expense', amount: 260, cat: 'transport', pay: 'debit_card'),
  Tx('giria', 'gastei 3 conto de bala', i: 'expense', amount: 3),
  Tx('giria', 'bora registrar: 44 na farmácia no pix', i: 'expense', amount: 44, cat: 'health', pay: 'pix'),
  Tx('giria', 'saí com a galera e rachei 68 no bar, mandei no pix', i: 'expense', amount: 68, cat: 'leisure', pay: 'pix'),
  Tx('giria', 'recebi o vale de 600 da firma', i: 'income', amount: 600),

  // ── fala transcrita (sem pontuação, números por extenso) ──
  Tx('voz', 'gastei quarenta e um reais no açougue no pix', i: 'expense', amount: 41, pay: 'pix'),
  Tx('voz', 'paguei oitocentos e setenta e cinco de aluguel no boleto', i: 'expense', amount: 875, cat: 'housing', pay: 'bank_slip'),
  Tx('voz', 'recebi mil novecentos e noventa de salário', i: 'income', amount: 1990, cat: 'salary'),
  Tx('voz', 'gastei doze e trinta na padaria no débito', i: 'expense', amount: 12.30, pay: 'debit_card'),
  Tx('voz', 'coloquei noventa de gasolina no pix', i: 'expense', amount: 90, cat: 'transport', pay: 'pix'),
  Tx('voz', 'paguei cento e quarenta e nove e noventa na farmácia no crédito à vista', i: 'expense', amount: 149.90, cat: 'health', pay: 'credit_card'),
  Tx('voz', 'recebi duzentos e cinquenta de um bico no pix', i: 'income', amount: 250, pay: 'pix'),
  Tx('voz', 'gastei sete reais no café', i: 'expense', amount: 7),
  Tx('voz', 'gastei seiscentos no conserto da máquina de lavar no crédito em três vezes', i: 'expense', amount: 600, pay: 'credit_card', inst: 3),
  Tx('voz', 'transferi trezentos e cinquenta pra poupança', i: 'transfer', amount: 350),
  Tx('voz', 'paguei cinquenta e cinco de internet no débito', i: 'expense', amount: 55, cat: 'housing', pay: 'debit_card'),
  Tx('voz', 'gastei quatrocentos e doze e oitenta no supermercado no débito', i: 'expense', amount: 412.80, cat: 'supermarket', pay: 'debit_card'),
  Tx('voz', 'recebi dois mil e cem do freela ontem', i: 'income', amount: 2100, day: -1),
  Tx('voz', 'gastei vinte e oito no uber anteontem no pix', i: 'expense', amount: 28, cat: 'transport', pay: 'pix', day: -2),
  Tx('voz', 'gastei dezesseis reais e vinte centavos no ônibus', i: 'expense', amount: 16.20, cat: 'transport'),
  Tx('voz', 'paguei setenta de água no pix', i: 'expense', amount: 70, cat: 'housing', pay: 'pix'),
  Tx('voz', 'gastei um mil e duzentos no celular novo no crédito em doze vezes', i: 'expense', amount: 1200, pay: 'credit_card', inst: 12),
  Tx('voz', 'gastei oitenta e quatro na pizza no dinheiro', i: 'expense', amount: 84, cat: 'leisure', pay: 'cash'),
  Tx('voz', 'recebi sete mil de salário hoje', i: 'income', amount: 7000, cat: 'salary'),
  Tx('voz', 'paguei duzentos e noventa e nove no curso online no pix', i: 'expense', amount: 299, cat: 'education', pay: 'pix'),
  Tx('voz', 'gastei trinta e três reais e trinta e três centavos no mercado no pix', i: 'expense', amount: 33.33, cat: 'supermarket', pay: 'pix'),
  Tx('voz', 'gastei cento e cinco no mecânico no débito', i: 'expense', amount: 105, cat: 'transport', pay: 'debit_card'),
  Tx('voz', 'paguei quinze de estacionamento no crédito à vista', i: 'expense', amount: 15, cat: 'transport', pay: 'credit_card'),
  Tx('voz', 'recebi oitenta de reembolso da empresa no pix', i: 'income', amount: 80, pay: 'pix'),
  Tx('voz', 'gastei novecentos e noventa e nove reais no sofá no crédito em dez vezes', i: 'expense', amount: 999, pay: 'credit_card', inst: 10),
  Tx('voz', 'gastei dois reais no cafezinho no dinheiro', i: 'expense', amount: 2, pay: 'cash'),
  Tx('voz', 'paguei quinhentos e sessenta de condomínio no boleto', i: 'expense', amount: 560, cat: 'housing', pay: 'bank_slip'),
  Tx('voz', 'gastei sessenta e sete na farmácia no pix', i: 'expense', amount: 67, cat: 'health', pay: 'pix'),
  Tx('voz', 'gastei vinte e três e noventa no ifood no débito', i: 'expense', amount: 23.90, cat: 'leisure', pay: 'debit_card'),
  Tx('voz', 'recebi três mil e quatrocentos de salário no pix', i: 'income', amount: 3400, cat: 'salary', pay: 'pix'),
  Tx('voz', 'gastei cinquenta conto no bar ontem à noite no pix', i: 'expense', amount: 50, cat: 'leisure', pay: 'pix', day: -1),
  Tx('voz', 'paguei cento e dez de luz no débito', i: 'expense', amount: 110, cat: 'housing', pay: 'debit_card'),
  Tx('voz', 'gastei quarenta reais na academia no pix', i: 'expense', amount: 40, cat: 'health', pay: 'pix'),
  Tx('voz', 'comprei um presente de cento e vinte e cinco no pix', i: 'expense', amount: 125, pay: 'pix'),
  Tx('voz', 'gastei oito reais e setenta e cinco centavos de pão', i: 'expense', amount: 8.75),

  // ── erros de digitação ──
  Tx('typo', 'gastie 64 no açouge no pics', i: 'expense', amount: 64, pay: 'pix'),
  Tx('typo', 'paguie 220 de aluguell no bolto', i: 'expense', amount: 220, cat: 'housing', pay: 'bank_slip'),
  Tx('typo', 'recebei 3100 de salrio', i: 'income', amount: 3100, cat: 'salary'),
  Tx('typo', 'gatei 19 no uberr no pix', i: 'expense', amount: 19, cat: 'transport', pay: 'pix'),
  Tx('typo', 'gastei 88 na framacia no debitoo', i: 'expense', amount: 88, cat: 'health', pay: 'debit_card'),
  Tx('typo', 'GASTEI 250 NO SUPERMERCADO NO CRÉDITO À VISTA', i: 'expense', amount: 250, cat: 'supermarket', pay: 'credit_card'),
  Tx('typo', 'cmprei 1 fone de 150 no pix', i: 'expense', amount: 150, pay: 'pix'),
  Tx('typo', 'abasteci 110 no posot no dinhero', i: 'expense', amount: 110, cat: 'transport', pay: 'cash'),
  Tx('typo', 'pagei 95 de interneet', i: 'expense', amount: 95, cat: 'housing'),
  Tx('typo', 'recebi 500 de frela no pixx', i: 'income', amount: 500, pay: 'pix'),
  Tx('typo', 'gastei 42 no restaurant no credito a vist', i: 'expense', amount: 42, cat: 'leisure', pay: 'credit_card'),
  Tx('typo', 'gastei 27,5 no cinmea no pix', i: 'expense', amount: 27.50, cat: 'leisure', pay: 'pix'),
  Tx('typo', 'gastie 13 no onbus', i: 'expense', amount: 13, cat: 'transport'),
  Tx('typo', 'Paguei 1.100 De Condominio No Boleto', i: 'expense', amount: 1100, cat: 'housing', pay: 'bank_slip'),
  Tx('typo', 'gstei 58 no mercdo no debto', i: 'expense', amount: 58, cat: 'supermarket', pay: 'debit_card'),
  Tx('typo', 'gastei 70 na academai no pix', i: 'expense', amount: 70, cat: 'health', pay: 'pix'),
  Tx('typo', 'reebi 1500 de salario', i: 'income', amount: 1500, cat: 'salary'),
  Tx('typo', 'gastei 36 de ubr ontem no pix', i: 'expense', amount: 36, cat: 'transport', pay: 'pix', day: -1),
  Tx('typo', 'gasteii 2000 na tv em 10x no credto', i: 'expense', amount: 2000, pay: 'credit_card', inst: 10),
  Tx('typo', 'paguie 180 no dentsta no pix', i: 'expense', amount: 180, cat: 'health', pay: 'pix'),
  Tx('typo', 'transferii 600 pra poupanca', i: 'transfer', amount: 600),
  Tx('typo', 'gastei 15reais na padaria no pix', i: 'expense', amount: 15, pay: 'pix'),
  Tx('typo', 'gastei R\$23,40no mercado no pix', i: 'expense', amount: 23.40, cat: 'supermarket', pay: 'pix'),
  Tx('typo', 'gastei 49 no ifod no pix', i: 'expense', amount: 49, cat: 'leisure', pay: 'pix'),
  Tx('typo', 'GASTEI 33 NA FARMÁCIA NO DÉBITO', i: 'expense', amount: 33, cat: 'health', pay: 'debit_card'),
  Tx('typo', 'gastie 125 de gasolna no credito a vista', i: 'expense', amount: 125, cat: 'transport', pay: 'credit_card'),
  Tx('typo', 'paguei 67 na cnta de agua', i: 'expense', amount: 67, cat: 'housing'),
  Tx('typo', 'gastei 90 no mecanico no pixx', i: 'expense', amount: 90, cat: 'transport', pay: 'pix'),
  Tx('typo', 'recebi 320 d freela no pix', i: 'income', amount: 320, pay: 'pix'),
  Tx('typo', 'gastie 18 no estacionamneto no dinheiro', i: 'expense', amount: 18, cat: 'transport', pay: 'cash'),
  Tx('typo', 'gastie 76 no petshop no pix', i: 'expense', amount: 76, pay: 'pix'),
  Tx('typo', 'pageui 140 de luz no pix', i: 'expense', amount: 140, cat: 'housing', pay: 'pix'),
  Tx('typo', 'gastie 11 no cafe no pix', i: 'expense', amount: 11, pay: 'pix'),
  Tx('typo', 'gastei 300 no hotell no credito em 3x', i: 'expense', amount: 300, pay: 'credit_card', inst: 3),
  Tx('typo', 'gastei 22 no merkado ontem no pics', i: 'expense', amount: 22, cat: 'supermarket', pay: 'pix', day: -1),
];

// ─────────────────────────── vários lançamentos numa frase ───────────────────────────

final multiScenarios = <Scn>[
  Scn('multi', 'farmácia + açougue pix', ['gastei 35 na farmácia e 60 no açougue no pix'], '35 + 60', (s, r) => amounts(s, [35, 60])),
  Scn('multi', 'internet + celular débito', ['paguei 120 de internet e 90 de celular no débito'], '120 + 90', (s, r) => amounts(s, [120, 90])),
  Scn('multi', 'três itens, "tudo no pix"', ['hoje gastei 18 no café, 42 no almoço e 25 no uber, tudo no pix'], '18 + 42 + 25', (s, r) => amounts(s, [18, 42, 25])),
  Scn('multi', 'gasolina + calibragem', ['coloquei 100 de gasolina e 30 de calibragem no débito'], '100 + 30', (s, r) => amounts(s, [100, 30])),
  Scn('multi', '"X por N e Y por M"', ['comprei pão por 9 e leite por 6 no dinheiro'], '9 + 6', (s, r) => amounts(s, [9, 6])),
  Scn('multi', 'pagamentos diferentes por item', ['gastei 200 no mercado no débito e 50 na farmácia no pix'], '200 débito + 50 pix',
      (s, r) => amounts(s, [200, 50], (m) => m.any((t) => t.amount == 200 && t.paymentMethod == 'debit_card') && m.any((t) => t.amount == 50 && t.paymentMethod == 'pix'))),
  Scn('multi', 'duas receitas', ['recebi 1500 de salário e 300 de freela no pix'], '1500 + 300 receitas',
      (s, r) => amounts(s, [1500, 300], (m) => m.every((t) => t.type == TransactionType.income))),
  Scn('multi', 'três contas no boleto', ['paguei 80 de água, 150 de luz e 99 de internet no boleto'], '80 + 150 + 99', (s, r) => amounts(s, [80, 150, 99])),
  Scn('multi', 'sem pagamento → pergunta compartilhada → pix', ['gastei 40 no cinema e 30 na pipoca', 'pix'], 'pergunta 1x; 40 + 30 pix',
      (s, r) => chain([
            () => r[0].route == 'ask_multi' ? null : 'turno 1: ${full(r[0])}',
            () => amounts(s, [40, 30], (m) => m.every((t) => t.paymentMethod == 'pix')),
          ])),
  Scn('multi', 'sem verbo: "almoço 32 e janta 48"', ['almoço 32 e janta 48 no pix'], '32 + 48', (s, r) => amounts(s, [32, 48])),
  Scn('multi', '"mais" como separador', ['gastei 25 na feira mais 15 no pastel no dinheiro'], '25 + 15', (s, r) => amounts(s, [25, 15])),
  Scn('multi', 'barbeiro + gorjeta', ['paguei 60 no barbeiro e 20 de gorjeta no pix'], '60 + 20 (ou 80 num só)',
      (s, r) => amounts(s, [60, 20]) == null || amounts(s, [80]) == null ? null : dumpMine(s)),
  Scn('multi', 'uber ida e volta', ['uber de 19 pra ir e 23 pra voltar no pix'], '19 + 23 transporte',
      (s, r) => amounts(s, [19, 23], (m) => m.every((t) => t.category == 'transport'))),
  Scn('multi', 'por extenso', ['gastei cinquenta no mercado e trinta na padaria no pix'], '50 + 30', (s, r) => amounts(s, [50, 30])),
  Scn('multi', '"e depois mais"', ['gastei 70 no mercado e depois mais 45 na farmácia no débito'], '70 + 45', (s, r) => amounts(s, [70, 45])),
  Scn('multi', 'livro + caderno crédito à vista', ['comprei um livro de 55 e um caderno de 20 no crédito à vista'], '55 + 20', (s, r) => amounts(s, [55, 20])),
  Scn('multi', 'pagamento na frente', ['no pix: 30 de pizza e 12 de refrigerante'], '30 + 12', (s, r) => amounts(s, [30, 12])),
  Scn('multi', 'despesa + receita na mesma frase', ['gastei 100 no posto e recebi 50 de reembolso no pix'], '100 despesa + 50 receita',
      (s, r) => amounts(s, [100, 50], (m) => m.any((t) => t.amount == 100 && t.type == TransactionType.expense) && m.any((t) => t.amount == 50 && t.type == TransactionType.income))),
  Scn('multi', 'vírgula + "tudo no débito"', ['paguei 45 no estacionamento, 30 no lava jato, tudo no débito'], '45 + 30', (s, r) => amounts(s, [45, 30])),
  Scn('multi', 'NÃO dividir: "ida e volta" com um valor', ['gastei 15 no ônibus ida e volta no pix'], '1 lançamento de 15', (s, r) => amounts(s, [15])),
  Scn('multi', 'NÃO dividir: itens + total', ['comprei 3 coxinhas e 2 sucos, total 31 no pix'], '1 lançamento de 31', (s, r) => amounts(s, [31])),
  Scn('multi', 'valores iguais', ['gastei 60 no mercado e 60 na farmácia no pix'], '60 + 60', (s, r) => amounts(s, [60, 60])),
  Scn('multi', 'dois envios para pessoas', ['mandei 100 pra minha mãe e 100 pro meu irmão no pix'], '100 + 100', (s, r) => amounts(s, [100, 100])),
  Scn('multi', 'centavos', ['gastei 12,50 no café e 8,90 no pão no débito'], '12,50 + 8,90', (s, r) => amounts(s, [12.50, 8.90])),
  Scn('multi', 'três com "e" repetido', ['gastei 300 no mercado e 80 no açougue e 40 na feira no pix'], '300 + 80 + 40', (s, r) => amounts(s, [300, 80, 40])),
];

// ─────────────────────────── comentários sem intenção de lançar ───────────────────────────

/// Sem número: não pode salvar nem abrir rascunho pedindo valor.
Scn chat(String p) => Scn('comentario', p, [p], 'só conversa: nada salvo, sem pedir valor',
    (s, r) => mine(s).isNotEmpty ? dumpMine(s) : (r[0].route == 'ask' || r[0].route == 'saved' ? 'abriu rascunho: ${full(r[0])}' : null));

/// Com número: o mínimo é não salvar (perguntar ainda é aceitável).
Scn chatNum(String p) => Scn('comentario', p, [p], 'nada salvo (número não é gasto meu)', (s, r) => mine(s).isNotEmpty ? '${dumpMine(s)} ${full(r[0])}' : null);

final commentScenarios = <Scn>[
  chat('a gasolina subiu de novo, absurdo'),
  chat('tô duro esse mês'),
  chat('nossa, a conta de luz veio alta'),
  chat('preciso parar de pedir ifood'),
  chat('acho que tô gastando muito com uber'),
  chat('o aluguel aqui é muito caro'),
  chat('meu salário não dá pra nada'),
  chat('queria ganhar mais'),
  chat('hoje eu não vou gastar nada'),
  chat('amanhã vou no mercado'),
  chat('semana que vem tenho que pagar o IPVA'),
  chat('se o dólar subir eu tô ferrado'),
  chat('nossa que semana difícil'),
  chat('tô pensando em trocar de carro'),
  chat('minha esposa reclamou que eu gasto muito'),
  chat('hoje é dia de pagamento aqui na firma'),
  chat('odeio pagar boleto'),
  chat('a feira hoje tava ótima'),
  chat('será que compensa assinar o gamepass?'),
  chatNum('o pão na padaria daqui custa 12 reais, um roubo'),
  chatNum('a Netflix aumentou pra 59, vou cancelar'),
  chatNum('meu vizinho gastou 5 mil numa tv'),
  chatNum('o uber tá cobrando 40 pra ir no centro, absurdo'),
  chatNum('o quilo do café no mercado tá 30 reais'),
  Scn('comentario', 'comentário e depois lançamento real', ['a gasolina tá pela hora da morte', 'gastei 20 na padaria no pix'],
      'só o 20 é salvo', (s, r) => amounts(s, [20])),
];

// ─────────────────────────── perguntas sobre os dados ───────────────────────────

Scn q(String phrase, String desc, String? Function(ChatSim s, Reply r) check, {List<String> before = const [], Setup? setup = seedA}) =>
    Scn('perguntas', phrase, [...before, phrase], desc, (s, r) => check(s, r.last), setup: setup);

final questionScenarios = <Scn>[
  q('quanto já foi embora esse mês?', 'total de despesas do mês', (s, r) => answer(s, r, spending, [brl(monthExp(s))])),
  q('quanto gastei nos últimos 7 dias?', 'soma dos últimos 7 dias', (s, r) {
    double win(int n) => s.repo.transactions
        .where((t) => t.type == TransactionType.expense && !t.date.isBefore(_day(n).subtract(const Duration(hours: 12))))
        .fold(0.0, (a, t) => a + t.amount);
    return answer(s, r, spending, [brl(win(6)), brl(win(7))]);
  }),
  q('quanto torrei de ifood?', 'iFood do mês', (s, r) => answer(s, r, spending, [brl(monthExp(s, (t) => titled(t, 'ifood')))])),
  q('qual foi meu gasto mais salgado esse mês?', 'maior = 1.400', (s, r) => answer(s, r, isReport, ['1.400,00'])),
  q('e o menor?', 'follow-up: menor gasto do mês', (s, r) {
    final m = s.repo.transactions.where((t) => t.type == TransactionType.expense && _thisMonth(t.date)).map((t) => t.amount).reduce((a, b) => a < b ? a : b);
    return answer(s, r, isReport, [brl(m)]);
  }, before: ['qual foi o maior gasto do mês?']),
  q('quanto saiu no dinheiro vivo?', 'dinheiro no mês', (s, r) => answer(s, r, spending, [brl(monthExp(s, (t) => t.paymentMethod == 'cash'))])),
  q('quanto gastei no débito semana passada?', 'débito, semana passada', (s, r) => answer(s, r, spending)),
  q('o que eu gastei ontem?', 'ontem = Posto 189', (s, r) => answer(s, r, isReport, ['189,00'])),
  q('quanto foi a farmácia?', 'farmácia 57,80', (s, r) => answer(s, r, spending, [brl(monthExp(s, (t) => t.category == 'health' && titled(t, 'farm')))])),
  q('qual categoria tá pesando mais?', 'Moradia', (s, r) => answer(s, r, isReport, ['Moradia'])),
  q('quanto ainda posso gastar com lazer?', 'lazer: 600 − gasto', (s, r) => answer(s, r, isReport, [brl(600 - monthExp(s, (t) => t.category == 'leisure'))])),
  q('meu saldo tá positivo?', 'overview', (s, r) => answer(s, r, overview)),
  q('qual foi minha renda em $thisMonthName?', 'receitas do mês (mês pelo nome)', (s, r) => answer(s, r, isReport, [brl(monthInc(s))])),
  q('quanto gastei em $lastMonthName?', 'despesas do mês passado pelo nome = 688,70', (s, r) => answer(s, r, spending, ['688,70'])),
  q('e no mês passado?', 'follow-up: luz do mês passado 176,40', (s, r) => answer(s, r, spending, ['176,40']), before: ['quanto foi de luz esse mês?']),
  q('e hoje?', 'follow-up: gastos de hoje (iFood 41,50)', (s, r) => answer(s, r, spending, ['41,50']), before: ['me fala os gastos de ontem']),
  q('e de açougue?', 'follow-up: açougue 112,00', (s, r) => answer(s, r, spending, ['112,00']), before: ['quanto paguei de mercado esse mês?']),
  q('e no dinheiro?', 'follow-up: dinheiro 125,00', (s, r) => answer(s, r, spending, [brl(monthExp(s, (t) => t.paymentMethod == 'cash'))]), before: ['quanto gastei no pix esse mês?']),
  q('quantas vezes pedi ifood esse mês?', 'contagem', (s, r) => answer(s, r, isReport, ['${s.repo.transactions.where((t) => titled(t, 'ifood') && _thisMonth(t.date)).length}'])),
  q('quando foi a última vez que fui ao cinema?', 'última vez Cinemark', (s, r) => answer(s, r, isReport, ['Cinemark'])),
  q('lista o que gastei essa semana', 'lista', (s, r) => answer(s, r, isReport)),
  q('tenho alguma conta pra vencer?', 'contas', (s, r) => answer(s, r, (x) => x == 'report:bills')),
  q('quem tá me devendo grana?', 'João', (s, r) => answer(s, r, (x) => x == 'report:debtors', ['João'])),
  q('o joão já me pagou?', 'João deve 150', (s, r) => answer(s, r, (x) => x == 'report:debtors', ['150'])),
  q('quanto recebi de salário?', '4.500', (s, r) => answer(s, r, isReport, ['4.500,00'])),
  q('quanto eu gasto por mês com academia?', '119,90', (s, r) => answer(s, r, spending, ['119,90'])),
  q('estou dentro do orçamento?', 'orçamento/overview', (s, r) => answer(s, r, isReport)),
  q('mostra meus últimos 3 gastos', 'recentes (iFood de hoje)', (s, r) => answer(s, r, isReport, ['iFood'])),
  q('quanto gastei com saúde e farmácia?', 'saúde do mês', (s, r) => answer(s, r, spending, [brl(monthExp(s, (t) => t.category == 'health'))])),
  q('quanto foi o gás?', 'gás 125,00', (s, r) => answer(s, r, spending, ['125,00'])),
  q('gastei mais esse mês ou no passado?', 'comparação', (s, r) => answer(s, r, overview)),
  q('quanto gastei de transporte ontem?', 'transporte ontem = 189,00', (s, r) => answer(s, r, spending, ['189,00'])),
  q('quanto sobrou até agora?', 'saldo (mês ou total)', (s, r) => answer(s, r, overview, [brl(monthInc(s) - monthExp(s)), brl(allBalance(s))])),
  q('qual o gasto mais caro da semana passada?', 'maior da semana passada', (s, r) => answer(s, r, isReport)),
  q('quanto gastei entre segunda e hoje?', 'intervalo por dia da semana', (s, r) => answer(s, r, spending)),
  // sem dados nenhum
  q('quanto já gastei até agora?', 'repo vazio: R\$ 0 / nada', (s, r) => answer(s, r, spending, ['0,00', 'nenhum', 'Nenhum', 'nada', 'Nada', 'não tem', 'não teve']), setup: seedEmpty),
  q('qual foi minha maior despesa?', 'repo vazio: sem despesa, sem inventar', (s, r) => answer(s, r, isReport, ['nenhum', 'Nenhum', 'nada', 'Nada', 'Ainda', 'ainda', 'não há', 'Não há', 'não tem', 'Não encontrei']), setup: seedEmpty),
  q('tem alguém me devendo?', 'repo vazio: ninguém', (s, r) => answer(s, r, (x) => x == 'report:debtors', ['ninguém', 'Ninguém', 'nenhum', 'Nenhum', 'nada', 'Nada']), setup: seedEmpty),
];

// ─────────────────────────── multi-turno ───────────────────────────

final convScenarios = <Scn>[
  Scn('multiturno', 'dentista → valor → débito', ['paguei o dentista', 'foram 350', 'no débito'], '350 saúde débito',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 350 && m.first.category == 'health' && m.first.paymentMethod == 'debit_card')),
  Scn('multiturno', 'remédio → valor por extenso → pix', ['comprei remédio pra gripe', 'trinta e dois e cinquenta', 'pix'], '32,50 saúde pix',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 32.50 && m.first.paymentMethod == 'pix')),
  Scn('multiturno', 'posto → "deixa pra lá"', ['gastei 80 no posto', 'deixa pra lá'], 'nada salvo', (s, r) => only(s, (m) => m.isEmpty)),
  Scn('multiturno', 'almoço → "para, não registra isso"', ['almocei por 36', 'para, não registra isso'], 'nada salvo', (s, r) => only(s, (m) => m.isEmpty)),
  Scn('multiturno', 'loja → "esquece, depois eu vejo"', ['gastei 150 na loja', 'esquece, depois eu vejo'], 'nada salvo', (s, r) => only(s, (m) => m.isEmpty)),
  Scn('multiturno', 'posto → "cancelar"', ['gastei 18 no uber', 'cancelar'], 'nada salvo', (s, r) => only(s, (m) => m.isEmpty)),
  Scn('multiturno', 'tênis crédito → "em 4 vezes"', ['comprei um tênis de 400 no crédito', 'em 4 vezes'], '400 crédito 4x',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 400 && m.first.installments == 4 && m.first.paymentMethod == 'credit_card')),
  Scn('multiturno', 'tênis crédito → "foi à vista"', ['comprei um tênis de 400 no crédito', 'foi à vista'], '400 crédito à vista',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 400 && (m.first.installments ?? 1) <= 1 && m.first.paymentMethod == 'credit_card')),
  Scn('multiturno', 'tênis crédito → "quatro parcelas"', ['comprei um tênis de 400 no crédito', 'quatro parcelas'], '400 crédito 4x',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 400 && m.first.installments == 4)),
  Scn('multiturno', 'crédito → "não quero parcelar"', ['gastei 99 na farmácia no crédito', 'não quero parcelar'], '99 crédito à vista',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 99 && (m.first.installments ?? 1) <= 1)),
  Scn('multiturno', 'assinatura → "todo dia 18"', ['assinei o youtube premium por 24,90 no crédito', 'todo dia 18'], 'recorrente dia 18',
      (s, r) => only(s, (m) => m.length == 1 && m.first.isRecurrent && m.first.dueDay == 18 && m.first.amount == 24.90)),
  Scn('multiturno', 'lança → pergunta do mês passado', ['gastei 60 no mercado no pix', 'e no mês passado quanto foi de mercado?'], '60 salvo; responde 512,30',
      (s, r) => chain([
            () => only(s, (m) => m.length == 1 && m.first.amount == 60),
            () => spending(r[1].route) && r[1].text.contains('512,30') ? null : 'pergunta: ${full(r[1])}',
          ]),
      setup: seedA),
  Scn('multiturno', 'mercado → "e de farmácia?" → "e anteontem?"', ['quanto gastei de mercado esse mês?', 'e de farmácia?', 'e anteontem?'], 'farmácia anteontem 57,80',
      (s, r) => answer(s, r.last, spending, ['57,80']), setup: seedA),
  Scn('multiturno', 'maior gasto → "e o segundo maior?"', ['qual meu maior gasto do mês?', 'e o segundo maior?'], 'segundo = 380,50',
      (s, r) => answer(s, r.last, isReport, ['380,50']), setup: seedA),
  Scn('multiturno', 'recebi? → "e gastei?"', ['quanto recebi esse mês?', 'e gastei?'], 'despesas do mês',
      (s, r) => answer(s, r.last, spending, [brl(monthExp(s))]), setup: seedA),
  Scn('multiturno', 'pix → "foi na farmácia"', ['gastei 25 no pix', 'foi na farmácia'], '25 saúde pix',
      (s, r) => only(s, (m) => m.length == 1 && m.first.category == 'health' && m.first.paymentMethod == 'pix')),
  Scn('multiturno', 'pix → "era remédio"', ['gastei 25 no pix', 'era remédio'], '25 saúde',
      (s, r) => only(s, (m) => m.length == 1 && m.first.category == 'health')),
  Scn('multiturno', '"paguei 90" → luz → boleto', ['paguei 90', 'luz', 'boleto'], '90 moradia boleto',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 90 && m.first.category == 'housing' && m.first.paymentMethod == 'bank_slip')),
  Scn('multiturno', '"recebi 700" → freela → pix', ['recebi 700', 'foi de um freela', 'pix'], '700 receita pix',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 700 && m.first.type == TransactionType.income && m.first.paymentMethod == 'pix')),
  Scn('multiturno', 'rascunho → pergunta → "pix" solto', ['gastei 40 no mercado', 'quanto eu gastei hoje?', 'pix'], 'sem lixo: nada ou 40 pix',
      (s, r) => only(s, (m) => m.isEmpty || (m.length == 1 && m.first.amount == 40 && m.first.paymentMethod == 'pix'))),
  Scn('multiturno', 'açougue → "e mais 14 na farmácia"', ['gastei 30 no açougue no pix', 'e mais 14 na farmácia'], '30 + 14, ambos pix',
      (s, r) => amounts(s, [30, 14], (m) => m.every((t) => t.paymentMethod == 'pix'))),
  Scn('multiturno', 'açougue → "ah, foi 35"', ['gastei 30 no açougue no pix', 'ah, foi 35'], '35 (1 lançamento)', (s, r) => amounts(s, [35])),
  Scn('multiturno', 'açougue → "não era pix, era dinheiro"', ['gastei 30 no açougue no pix', 'não era pix, era dinheiro'], 'dinheiro',
      (s, r) => only(s, (m) => m.length == 1 && m.first.paymentMethod == 'cash')),
  Scn('multiturno', 'açougue → "isso foi anteontem"', ['gastei 30 no açougue no pix', 'isso foi anteontem'], 'data anteontem',
      (s, r) => only(s, (m) => m.length == 1 && m.first.date.day == _day(2).day && m.first.date.month == _day(2).month)),
  Scn('multiturno', 'açougue → desfaz → desfaz', ['gastei 30 no açougue no pix', 'desfaz', 'desfaz'], 'nada salvo; demo intacta',
      (s, r) => only(s, (m) => m.isEmpty) ?? (collateral(s, {}).isEmpty ? null : collateral(s, {}).join('; '))),
  Scn('multiturno', 'empréstimo → devolução parcial', ['emprestei 120 pro Rafael no pix', 'o rafael me devolveu 50'], 'Rafael deve 70',
      (s, r) {
    final d = s.repo.findDebtorsByName('Rafael');
    return d.isNotEmpty && d.first.amount == 70 ? null : 'Rafael: ${d.map((e) => e.amount).toList()} / ${r.map(full).join(' | ')} / ${dumpMine(s)}';
  }),
  Scn('multiturno', 'meta → aporte → quanto tenho?', ['quero guardar 1200 pra um celular novo até dezembro', 'coloca 150 na meta do celular', 'quanto já tenho guardado pro celular?'],
      'meta 150; resposta contém 150', (s, r) => chain([
            () => s.repo.goals.isNotEmpty && s.repo.goals.first.savedAmount == 150 ? null : 'metas: ${s.repo.goals.map((g) => '${g.title} ${g.savedAmount}').toList()} / ${full(r[1])}',
            () => r[2].text.contains('150') ? null : 'pergunta: ${full(r[2])}',
            () => only(s, (m) => m.isEmpty),
          ])),
  Scn('multiturno', 'lança → saldo → "muda aquele pra 65"', ['gastei 55 no mercado no débito', 'qual meu saldo?', 'muda aquele pra 65'], '65 (1 lançamento)',
      (s, r) => amounts(s, [65])),
  Scn('multiturno', 'dois → "o do mercado era 58"', ['gastei 55 no mercado no débito', 'gastei 20 no uber no pix', 'o do mercado era 58'], 'mercado 58, uber 20',
      (s, r) => amounts(s, [58, 20])),
  Scn('multiturno', 'passagem → crédito → 3x', ['comprei uma passagem de ônibus de 350', 'crédito', '3x'], '350 crédito 3x',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 350 && m.first.installments == 3 && m.first.paymentMethod == 'credit_card')),
  Scn('multiturno', 'sacolão → crédito à vista → "opa, foi no débito"', ['gastei 70 no sacolão', 'crédito à vista', 'opa, foi no débito'], '70 débito',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 70 && m.first.paymentMethod == 'debit_card')),
  Scn('multiturno', 'valor → categoria → corrige valor', ['gastei 45 no pix', 'mercado', 'na verdade foi 54'], '54 mercado',
      (s, r) => only(s, (m) => m.length == 1 && m.first.amount == 54 && m.first.category == 'supermarket')),
  Scn('multiturno', 'saudação → lança → agradece', ['oi césar', 'gastei 20 na farmácia no pix', 'brigado'], '1 lançamento de 20', (s, r) => amounts(s, [20])),
  Scn('multiturno', 'semana → "e na semana passada?"', ['quanto gastei essa semana?', 'e na semana passada?'], 'relatório semana passada',
      (s, r) => answer(s, r.last, spending, ['semana passada']), setup: seedA),
  Scn('multiturno', 'gás → "e de luz no mês passado?"', ['quanto paguei de gás?', 'e de luz no mês passado?'], 'luz mês passado 176,40',
      (s, r) => answer(s, r.last, spending, ['176,40']), setup: seedA),
];

// ─────────────────────────── edição / exclusão / desfazer por referência ───────────────────────────

String wdName(int weekday) => _weekdayNames[weekday - 1];

final refScenarios = <Scn>[
  // ── dia da semana: bate (segunda = ontem hoje) ──
  Scn('referencia', 'apaga a feira de segunda (segunda=ontem hoje; distrator: feira de sexta + padaria de segunda)', ['apaga a feira de segunda', 'sim'],
      'confirma e apaga SÓ a feira de segunda', (s, r) => deleted(s, r, 0, {'r3-feiraseg'}), setup: seedMonYest),
  Scn('referencia', 'exclui a feira da segunda-feira', ['exclui a feira da segunda-feira', 'sim'], 'apaga só a feira de segunda',
      (s, r) => deleted(s, r, 0, {'r3-feiraseg'}), setup: seedMonYest),
  Scn('referencia', 'a feira de segunda foi 58', ['a feira de segunda foi 58'], 'feira de segunda = 58, a de sexta intacta',
      (s, r) => edited(s, r, 'r3-feiraseg', (t) => t.amount == 58), setup: seedMonYest),
  Scn('referencia', 'muda a feira de ontem pra 61', ['muda a feira de ontem pra 61'], 'feira de ontem = 61 (só vale se segunda=ontem)',
      (s, r) => backTo(DateTime.monday) == 1 ? edited(s, r, 'r3-feiraseg', (t) => t.amount == 61) : null, setup: seedMonYest),
  Scn('referencia', 'a feira de sexta foi no pix', ['a feira de sexta foi no pix'], 'feira de sexta = pix, a de segunda intacta',
      (s, r) => edited(s, r, 'r3-feirasex', (t) => t.paymentMethod == 'pix'), setup: seedMonYest),
  // ── dia da semana: feira numa segunda de 2+ dias atrás, com feira mais recente no sábado.
  // Se a última segunda foi ONTEM (caso de hoje), "a feira de segunda" é a de ontem, que
  // não existe: o certo é dizer que não achou e mostrar candidatas — nunca mexer na de sábado.
  Scn('referencia', 'tira a feira de segunda (feira mais recente no sábado)', ['tira a feira de segunda', 'sim'],
      backTo(DateTime.monday) == 1 ? 'segunda=ontem: não acha; lista candidatas; não mexe em nada' : 'apaga a de segunda, não a de sábado',
      (s, r) => backTo(DateTime.monday) == 1
          ? (['not_found', 'choose'].contains(r[0].route) ? untouched(s, r) : 'rota: ${full(r[0])} / ${untouched(s, r) ?? ''}')
          : deleted(s, r, 0, {'r3-feiraseg2'}),
      setup: seedMonOld),
  Scn('referencia', 'a feira de segunda foi no débito (feira mais recente no sábado)', ['a feira de segunda foi no débito'],
      backTo(DateTime.monday) == 1 ? 'segunda=ontem: não acha e diz isso (não "não consegui identificar"); não mexe em nada' : 'a de segunda = débito',
      (s, r) => backTo(DateTime.monday) == 1
          ? (['not_found', 'choose', 'ask_target'].contains(r[0].route) ? untouched(s, r) : 'resposta inútil: ${full(r[0])} / ${untouched(s, r) ?? 'nada mudou'}')
          : edited(s, r, 'r3-feiraseg2', (t) => t.paymentMethod == 'debit_card'),
      setup: seedMonOld),
  Scn('referencia', 'apaga a feira de sábado', ['apaga a feira de sábado', 'sim'], 'apaga a de sábado',
      (s, r) => deleted(s, r, 0, {'r3-feirasab'}), setup: seedMonOld),
  // ── dia da semana: NÃO bate (só existe feira na quinta) ──
  Scn('referencia', 'apaga a feira de segunda (só há feira na quinta)', ['apaga a feira de segunda', 'sim'],
      'não acha na segunda; se oferecer a de quinta, tem de dizer que é de quinta', (s, r) {
    if (r[0].route == 'confirm_delete' && !r[0].text.toLowerCase().contains(wdName(DateTime.thursday))) {
      return 'propôs apagar outro item sem avisar o dia: ${full(r[0])} / ${dumpId(s, 'r3-feiraqui')}';
    }
    if (r[0].route == 'confirm_delete') return null;
    return untouched(s, r);
  }, setup: seedNoMatch),
  Scn('referencia', 'a feira de segunda foi 60 (só há feira na quinta)', ['a feira de segunda foi 60'], 'não edita a de quinta; diz que não achou na segunda',
      (s, r) => ['not_found', 'choose', 'ask_target', 'ask_correction_or_new'].contains(r[0].route) ? untouched(s, r) : 'resposta inútil: ${full(r[0])} / ${untouched(s, r) ?? 'nada mudou'}',
      setup: seedNoMatch),
  Scn('referencia', 'o cinema de sábado foi no débito', ['o cinema de sábado foi no débito'], 'cinema = débito',
      (s, r) => edited(s, r, 'r3-cinesab', (t) => t.paymentMethod == 'debit_card'), setup: seedSat),
  Scn('referencia', 'apaga o cinema de domingo (cinema foi sábado)', ['apaga o cinema de domingo', 'sim'], 'não apaga o de sábado sem avisar',
      (s, r) {
    if (r[0].route == 'confirm_delete' && !r[0].text.toLowerCase().contains('sábado')) {
      return 'propôs apagar outro item sem avisar o dia: ${full(r[0])} / ${dumpId(s, 'r3-cinesab')}';
    }
    if (r[0].route == 'confirm_delete') return null;
    return untouched(s, r);
  }, setup: seedSat),
  // ── por nome / valor / data (conjunto A) ──
  Scn('referencia', 'o açougue de 112 foi no débito', ['o açougue de 112 foi no débito'], 'açougue = débito',
      (s, r) => edited(s, r, 'r3-acougue', (t) => t.paymentMethod == 'debit_card'), setup: seedA),
  Scn('referencia', 'deleta o açougue → pode', ['deleta o açougue', 'pode'], 'apaga açougue', (s, r) => deleted(s, r, 0, {'r3-acougue'}), setup: seedA),
  Scn('referencia', 'apaga o ifood (2) → "o de hoje" → sim', ['apaga o ifood', 'o de hoje', 'sim'], 'pergunta qual; apaga o de hoje',
      (s, r) => r[0].route != 'choose' ? 'não perguntou qual: ${full(r[0])}' : deleted(s, r, 1, {'r3-ifood1'}), setup: seedA),
  Scn('referencia', 'o ifood de 73,90 foi no pix', ['o ifood de 73,90 foi no pix'], 'ifood2 = pix', (s, r) => edited(s, r, 'r3-ifood2', (t) => t.paymentMethod == 'pix'), setup: seedA),
  Scn('referencia', 'exclui o gás → não', ['exclui o gás', 'não'], 'pede confirmação; mantém',
      (s, r) => r[0].route != 'confirm_delete' ? 'não pediu confirmação: ${full(r[0])}' : untouched(s, r), setup: seedA),
  Scn('referencia', 'o gás na verdade foi 130', ['o gás na verdade foi 130'], 'gás = 130', (s, r) => edited(s, r, 'r3-gas', (t) => t.amount == 130), setup: seedA),
  Scn('referencia', 'o gás foi no pix', ['o gás foi no pix'], 'gás = pix', (s, r) => edited(s, r, 'r3-gas', (t) => t.paymentMethod == 'pix'), setup: seedA),
  Scn('referencia', 'aquele da farmácia era 75,80', ['aquele da farmácia era 75,80'], 'farmácia = 75,80', (s, r) => edited(s, r, 'r3-farm', (t) => t.amount == 75.80), setup: seedA),
  Scn('referencia', 'apaga o de 57,80 → sim', ['apaga o de 57,80', 'sim'], 'apaga farmácia', (s, r) => deleted(s, r, 0, {'r3-farm'}), setup: seedA),
  Scn('referencia', 'apaga o de 57,80 → sim → desfaz', ['apaga o de 57,80', 'sim', 'desfaz'], 'farmácia volta', (s, r) => untouched(s, r), setup: seedA),
  Scn('referencia', 'muda o posto de ontem pra crédito', ['muda o posto de ontem pra crédito'], 'posto = crédito',
      (s, r) => edited(s, r, 'r3-posto', (t) => t.paymentMethod == 'credit_card'), setup: seedA),
  Scn('referencia', 'o posto de ontem foi 198', ['o posto de ontem foi 198'], 'posto = 198', (s, r) => edited(s, r, 'r3-posto', (t) => t.amount == 198), setup: seedA),
  Scn('referencia', 'remove o gasto de ontem → sim', ['remove o gasto de ontem', 'sim'], 'apaga posto (único de ontem)', (s, r) => deleted(s, r, 0, {'r3-posto'}), setup: seedA),
  Scn('referencia', 'apaga os gastos de ontem e de hoje → sim', ['apaga os gastos de ontem e de hoje', 'sim'], 'apaga posto + ifood de hoje',
      (s, r) => deleted(s, r, 0, {'r3-posto', 'r3-ifood1'}), setup: seedA),
  Scn('referencia', 'o mercado do mês passado foi 520', ['o mercado do mês passado foi 520'], 'mercado ant. = 520',
      (s, r) => edited(s, r, 'r3-mercant', (t) => t.amount == 520), setup: seedA),
  Scn('referencia', 'o mercado de <mês passado pelo nome> foi 530', ['o mercado de $lastMonthName foi 530'], 'mercado ant. = 530',
      (s, r) => edited(s, r, 'r3-mercant', (t) => t.amount == 530), setup: seedA),
  Scn('referencia', 'apaga a luz do mês passado → sim', ['apaga a luz do mês passado', 'sim'], 'apaga luz ant.', (s, r) => deleted(s, r, 0, {'r3-luzant'}), setup: seedA),
  Scn('referencia', 'renomeia o açougue pra Casa de Carnes', ['renomeia o açougue pra Casa de Carnes'], 'título Casa de Carnes',
      (s, r) => edited(s, r, 'r3-acougue', (t) => t.title == 'Casa de Carnes'), setup: seedA),
  Scn('referencia', 'passa o cinema pra educação', ['passa o cinema pra educação'], 'cinema = education', (s, r) => edited(s, r, 'r3-cinema', (t) => t.category == 'education'), setup: seedA),
  Scn('referencia', 'o açougue foi ontem', ['o açougue foi ontem'], 'açougue data = ontem',
      (s, r) => edited(s, r, 'r3-acougue', (t) => t.date.day == _day(1).day && t.date.month == _day(1).month), setup: seedA),
  Scn('referencia', 'apaga a academia → sim', ['apaga a academia', 'sim'], 'apaga academia (demo)', (s, r) => deleted(s, r, 0, {'init-4'}), setup: seedA),
  Scn('referencia', 'o do cinema foi 46 e no pix', ['o do cinema foi 46 e no pix'], 'cinema 46 pix',
      (s, r) => edited(s, r, 'r3-cinema', (t) => t.amount == 46 && t.paymentMethod == 'pix'), setup: seedA),
  Scn('referencia', 'esse do ifood de hoje foi 45', ['esse do ifood de hoje foi 45'], 'ifood1 = 45', (s, r) => edited(s, r, 'r3-ifood1', (t) => t.amount == 45), setup: seedA),
  Scn('referencia', 'apaga o de 999 (não existe)', ['apaga o de 999'], 'não acha, nada muda',
      (s, r) => r[0].route == 'not_found' ? untouched(s, r) : 'rota: ${full(r[0])} / ${untouched(s, r) ?? ''}', setup: seedA),
  Scn('referencia', 'apaga a padaria (não existe no conjunto A)', ['apaga a padaria'], 'não acha, não oferece outro',
      (s, r) => r[0].route == 'not_found' ? untouched(s, r) : 'rota: ${full(r[0])}', setup: seedA),
  Scn('referencia', 'cancela aquele ifood de 41,50 → sim', ['cancela aquele ifood de 41,50', 'sim'], 'apaga ifood1', (s, r) => deleted(s, r, 0, {'r3-ifood1'}), setup: seedA),
  Scn('referencia', 'o gás foi 130 → desfaz', ['o gás na verdade foi 130', 'desfaz'], 'gás volta a 125', (s, r) => untouched(s, r), setup: seedA),
];

// ─────────────────────────── futuro (linha de base; fora do R3TOTAL) ───────────────────────────

Scn fut(String phrase, String desc, String? Function(ChatSim s, Reply r) check, {List<String> before = const [], Setup? setup = seedA}) =>
    Scn('futuro', phrase, [...before, phrase], desc, (s, r) => check(s, r.last), setup: setup);

final futureScenarios = <Scn>[
  // simulações
  fut('se eu pagar o aluguel agora, quanto me sobra?', 'simulação: saldo − 1.400',
      (s, r) => answer(s, r, anyAnswer, [brl(monthInc(s) - monthExp(s) - 1400), brl(allBalance(s) - 1400)])),
  fut('se eu cortar delivery quanto economizo?', 'simulação: total de iFood/delivery do mês',
      (s, r) => answer(s, r, anyAnswer, [brl(monthExp(s, (t) => titled(t, 'ifood')))])),
  fut('se eu guardar 200 por mês quando bato a meta?', 'meta 3000 ÷ 200 = 15 meses',
      (s, r) => answer(s, r, anyAnswer, ['15 meses']), before: ['quero juntar 3000 pra uma moto até dezembro de 2027']),
  fut('se eu comprar um celular de 2000 em 10x, quanto fica por mês?', '200,00 por mês', (s, r) => answer(s, r, anyAnswer, ['200,00'])),
  fut('quanto eu teria hoje se não tivesse pedido ifood?', 'saldo + iFood',
      (s, r) => answer(s, r, anyAnswer, [brl(monthInc(s) - monthExp(s) + monthExp(s, (t) => titled(t, 'ifood'))), brl(allBalance(s) + monthExp(s, (t) => titled(t, 'ifood')))])),
  fut('em quanto tempo eu junto 5 mil guardando 500 por mês?', '10 meses', (s, r) => answer(s, r, anyAnswer, ['10 meses'])),
  fut('se meu salário aumentar 10%, quanto sobra por mês?', 'simulação com 4.950', (s, r) => answer(s, r, anyAnswer, ['4.950'])),
  // consultor
  fut('onde posso economizar?', 'aponta categoria(s) concretas', (s, r) => answer(s, r, anyAnswer, ['Lazer', 'Moradia', 'Supermercado', 'iFood'])),
  fut('como vou fechar o mês?', 'projeção de fim de mês', (s, r) => answer(s, r, anyAnswer, ['previs', 'Previs', 'projeç', 'Projeç', 'fechar', 'fim do mês'])),
  fut('quanto vai vir a conta de luz?', 'estimativa pela última luz (176,40)', (s, r) => answer(s, r, anyAnswer, ['176,40'])),
  fut('quais assinaturas eu pago?', 'lista recorrentes (Academia)', (s, r) => answer(s, r, anyAnswer, ['Academia', 'SmartFit'])),
  fut('quais são meus gastos fixos?', 'Aluguel + Academia', (s, r) => answer(s, r, anyAnswer, ['Aluguel']) ?? answer(s, r, anyAnswer, ['Academia'])),
  fut('quanto eu gasto por ano com academia?', '119,90 × 12 = 1.438,80', (s, r) => answer(s, r, anyAnswer, ['1.438,80'])),
  fut('qual dia da semana eu mais gasto?', 'nome de dia da semana', (s, r) => answer(s, r, anyAnswer, ['segunda', 'terça', 'quarta', 'quinta', 'sexta', 'sábado', 'domingo'])),
  fut('qual foi o mês que eu mais gastei?', 'mês com mais gasto (este)', (s, r) => answer(s, r, anyAnswer, [thisMonthName])),
  fut('tô gastando mais com ifood que no mês passado?', 'comparação filtrada (iFood)', (s, r) => answer(s, r, anyAnswer, [brl(monthExp(s, (t) => titled(t, 'ifood')))])),
  fut('me avisa se eu passar de 500 no lazer', 'alerta/limite de lazer 500',
      (s, r) => (r.route == 'budget_set' || r.text.toLowerCase().contains('aviso')) && mine(s).isEmpty ? null : full(r)),
  // média diária real
  fut('em média quanto eu gasto por dia?', 'média real = gasto do mês ÷ dias corridos',
      (s, r) => answer(s, r, anyAnswer, [brl(monthExp(s) / _now.day)])),
  fut('qual meu gasto médio diário com mercado?', 'mercado do mês ÷ dias corridos',
      (s, r) => answer(s, r, anyAnswer, [brl(monthExp(s, (t) => t.category == 'supermarket') / _now.day)])),
  fut('quanto gasto por semana em média?', 'gasto do mês ÷ semanas corridas',
      (s, r) => answer(s, r, anyAnswer, [brl(monthExp(s) / (_now.day / 7))])),
];

// ─────────────────────────── execução ───────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  ChatSim fresh([Setup? setup]) {
    final repo = FinancialRepository();
    setup?.call(repo);
    _snapshot = {for (final t in repo.transactions) t.id: fmt(t)};
    return ChatSim(engine, repo);
  }

  test('conversation probe r3 (generalização)', () {
    final pass = <String, int>{};
    final total = <String, int>{};
    void score(String axis, bool ok) {
      total[axis] = (total[axis] ?? 0) + 1;
      if (ok) pass[axis] = (pass[axis] ?? 0) + 1;
    }

    print('R3INFO hoje=${_now.toIso8601String().substring(0, 10)} (weekday ${_now.weekday}); segunda=${backTo(DateTime.monday)}d atrás; '
        'mês passado=$lastMonthName');

    for (final c in txCases) {
      final problems = <String>[];
      Reply? r;
      try {
        final sim = fresh();
        r = sim.send(c.phrase);
        final d = r.draft;
        if (d == null) {
          problems.add('route ${r.route} (sem rascunho)');
        } else {
          // Regras de produto: perguntar pagamento (quando a frase não diz),
          // "parcelado ou à vista?" no crédito, o dia de uma assinatura e a
          // categoria (uma vez) de algo desconhecido NÃO são falha.
          final okAsk = d.missingSlots.every((m) =>
              (m == 'payment_method' && c.pay == null) ||
              (m == 'installments' && c.inst == null) ||
              (m == 'due_day' && c.recurrent == null) ||
              (m == 'category' && c.cat == null));
          if (!d.isComplete && !okAsk) problems.add('ficou perguntando ${d.missingSlots}');
          if (c.intent != null && !c.intent!.contains(d.intent)) problems.add('intent ${d.intent}≠${c.intent}');
          if (c.amount != null && (d.amount == null || (d.amount! - c.amount!).abs() > 0.001)) problems.add('valor ${d.amount}≠${c.amount}');
          if (c.cat != null && !c.cat!.contains(d.category)) problems.add('cat ${d.category}≠${c.cat}');
          if (c.pay != null && d.paymentMethod != c.pay) problems.add('pag ${d.paymentMethod}≠${c.pay}');
          if (c.inst != null && d.installments != c.inst) problems.add('parc ${d.installments}≠${c.inst}');
          if (c.day != null && d.dateOffsetDays != c.day) problems.add('dia ${d.dateOffsetDays}≠${c.day}');
          if (c.recurrent != null && d.isRecurrent != c.recurrent) problems.add('rec ${d.isRecurrent}≠${c.recurrent}');
        }
      } catch (e) {
        problems.add('EXCEPTION $e');
      }
      final ok = problems.isEmpty;
      score(c.axis, ok);
      if (!ok) {
        final silent = r != null && (r.route == 'saved' || r.route == 'multi') &&
            problems.any((p) => p.startsWith('valor') || p.startsWith('intent') || p.startsWith('dia'));
        print('R3FAIL [${c.axis}]${silent ? ' [P0?]' : ''} "${c.phrase}" => $r || ${problems.join('; ')}');
      }
    }

    String? runScn(Scn s, String prefix) {
      String? problem;
      final sim = fresh(s.setup);
      try {
        for (final t in s.turns) {
          sim.send(t);
        }
        problem = s.check(sim, sim.log);
      } catch (e, st) {
        problem = 'EXCEPTION $e ${st.toString().split('\n').take(3).join(' ')}';
      }
      if (problem != null || prefix == 'R3FUT') {
        print('$prefix [${s.axis}]${problem == null ? ' OK' : ''} ${s.name}: ${s.turns.join(' ⏎ ')} || esperado: ${s.expected}${problem == null ? '' : ' || $problem'}');
        for (var i = 0; i < sim.log.length; i++) {
          print('$prefix      turno ${i + 1} "${s.turns[i]}" => ${full(sim.log[i])}${sim.log[i].draft == null ? '' : ' ${sim.log[i]}'}');
        }
      }
      return problem;
    }

    for (final s in [...multiScenarios, ...commentScenarios, ...questionScenarios, ...convScenarios, ...refScenarios]) {
      score(s.axis, runScn(s, 'R3FAIL') == null);
    }

    var p = 0, t = 0;
    for (final axis in total.keys) {
      p += pass[axis] ?? 0;
      t += total[axis]!;
      print('R3AXIS $axis ${pass[axis] ?? 0}/${total[axis]}');
    }
    print('R3TOTAL $p/$t');

    var fp = 0;
    for (final s in futureScenarios) {
      if (runScn(s, 'R3FUT') == null) fp++;
    }
    print('R3FUTURE $fp/${futureScenarios.length}');
  });
}
