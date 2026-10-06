// Teste do caos — Item 2, lote A, REVALIDAÇÃO depois das correções 7a + 7b
// (cesar-chaos, etapa 6' do portão de qualidade do PLANO_CESAR.md).
//
// NÃO falha a suíte: só imprime, com o prefixo `CHAOS-B|`.
//   flutter test test/_qa/chaos_lote_a_r2_test.dart 2>&1 | grep "CHAOS-B|"
//   # só violações:  ... | grep -E "CHAOS-B\|(ALVO-V|REFCLOCK-V|RELOGIO-V|MIN|RESUMO|FUZZ\| primeira)"
//   # mais volume:   B_SEEDS=60 B_LEN=300 flutter test test/_qa/chaos_lote_a_r2_test.dart
//
// Mira as regras NOVAS da 7a/7b com vocabulário, títulos e seeds NOVOS
// (20261200+n): `MoneyDirection.unclear` e as regras por papel, o
// `HypothesisDetector` reescrito, a contagem de valores monetários
// (`otherMoneyValues`), `_parseDateOffset`/`SpokenDayParser` (títulos com
// palavra de data, dd/mm sem contexto, data da resposta, data compartilhada
// no multi), o rascunho pendente e o resolvedor de referência.
//
// `SimB` espelha `_sendMessage` do chat_screen.dart na ordem ATUAL — inclusive
// o passo da 7a que responde a hipótese antes do merge do lote pendente
// (`hypothesisReply`), que o `Sim3` do chaos_r3_support ainda não tem.
// Achados em docs/qa/findings-caos-lote-a-r2.md (IDs CHAOS-B-…).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/ai/category_name_matcher.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/cesar_text.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/goal_parser.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/ai/temporal_date_parser.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chaos_r3_support.dart';

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);
final DateTime today = _day(DateTime.now());
String ddmmyy(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
int _daysIn(int y, int m) => DateTime(y, m + 1, 0).day;
DateTime back(int n, [DateTime? now]) {
  final t = _day(now ?? today);
  return DateTime(t.year, t.month, t.day - n);
}

/// Última ocorrência (1–7 dias atrás) do dia da semana [wd].
DateTime wdLast(int wd, [DateTime? now]) {
  final t = _day(now ?? today);
  var b = (t.weekday - wd) % 7;
  if (b == 0) b = 7;
  return DateTime(t.year, t.month, t.day - b);
}

/// "dia N" ao lançar: o dia N mais recente que já passou (este mês ou o anterior).
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

/// "dd/mm" sem ano. Já passou neste ano → este ano. Ainda não chegou → é uma
/// data FUTURA e o certo é PERGUNTAR (null + ask) — exceto o "31/12" dito
/// logo no começo do ano (≤ 62 dias atrás no ano passado), que é o ano passado.
({DateTime? date, bool ask}) ddmmOracle(int d, int m, [DateTime? now]) {
  final t = _day(now ?? today);
  if (m < 1 || m > 12) return (date: null, ask: true);
  final ahead = m > t.month || (m == t.month && d > t.day);
  if (!ahead) {
    if (d < 1 || d > _daysIn(t.year, m)) return (date: null, ask: true);
    return (date: DateTime(t.year, m, d), ask: false);
  }
  final y = t.year - 1;
  if (d >= 1 && d <= _daysIn(y, m) && t.difference(DateTime(y, m, d)).inDays <= 62) return (date: DateTime(y, m, d), ask: false);
  return (date: null, ask: true);
}

/// Um turno com o que o gerador SABE sobre ele (o oráculo).
class LT {
  final String text;
  String family;
  String? dir; // 'income' | 'expense' — o sinal que a frase tem
  bool obviousDir = false; // direção óbvia: perguntar "entrou ou saiu?" é irritante (P2)
  bool dirAskOk = true; // perguntar a direção é aceitável
  List<double> values = const []; // valores monetários ditos (um por lançamento)
  double? single; // frase de 1 lançamento: o valor certo
  Set<double> singleAlt = const {}; // outros valores aceitáveis
  DateTime? expDate; // data que a frase diz (ou hoje)
  Set<DateTime> expAlt = const {}; // outras datas aceitáveis ("quarta" dita numa quarta)
  bool mustAsk = false; // data futura / inexistente / período: não pode salvar sem perguntar
  bool titleDate = false; // palavra de data só dentro do nome do lugar/endereço
  bool vagueDate = false; // "semana passada", "esses dias": data vaga (P2 se assumida sem aviso)
  bool? hyp; // true = hipótese/intenção; false = fato registrável com "se/caso"
  bool notHappened = false; // "quase comprei", "desisti de…", "ainda não paguei"
  String? named; // nome dito numa edição/exclusão
  double? editValue; // "muda … pra N": o valor novo
  bool recurrenceOk = false;
  bool pendingAnswer = false; // resposta a "quanto foi?"
  Map<double, String> valueDir = const {}; // multi misto: direção de cada valor
  Map<double, DateTime> valueDate = const {}; // multi com data por item
  String? newWord; // frase nova completa com rascunho pendente: palavra do item novo
  String? oldWord; // … e a palavra do rascunho antigo
  bool oneValueOnly = false; // frase de 1 valor (pedir split é irritante, P2)
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

// ───────────────────────── simulador do chat (ordem atual) ─────────────────────────

class SimB {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  FinancialTransactionDraft? active;
  FinancialTransactionDraft? last;
  List<String> lastIds = const [];
  List<FinancialTransactionDraft>? pendingBatch;
  static int _goalSeq = 0;

  SimB(this.engine, this.repo, {DateTime Function()? now}) : assistant = CesarAssistant(repository: repo, engine: engine, now: now);

  R3Reply send(String input) {
    final r = _send(input.trim());
    final notice = assistant.takeNotice();
    if (notice != null) return R3Reply(r.route, '$notice\n\n${r.text}', r.draft);
    return r;
  }

  void _saved(List<String> ids) {
    lastIds = ids;
    assistant.recordCreated(ids);
  }

  void _sync(AssistantReply reply) {
    if (lastIds.any(reply.removedIds.contains)) {
      lastIds = const [];
      last = null;
    }
  }

  R3Reply _send(String input) {
    var text = input;
    if (text.isEmpty) return R3Reply('empty_ignored', '(chat ignora mensagem vazia)');
    engine.setCustomCategories(repo.customCategoryNames);
    assistant.beginTurn();

    if (active != null && !active!.isComplete && engine.isCancelCommand(text)) {
      active = null;
      return R3Reply('cancel_pending', 'Tudo bem, descartei esse lançamento.');
    }

    if (pendingBatch != null) {
      final batch = pendingBatch!;
      if (engine.isCancelCommand(text)) {
        pendingBatch = null;
        return R3Reply('cancel_pending', 'Tudo bem, descartei esses lançamentos.');
      }
      // 7a: "e se fosse no pix?" com lote pendente é respondida e o lote espera.
      final whatIf = assistant.hypothesisReply(text);
      if (whatIf != null) return R3Reply(whatIf.route, whatIf.text);
      final firstOpen = batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first);
      if (!engine.startsNewTransaction(firstOpen, text)) {
        final merged = engine.mergeMultiDrafts(batch, text);
        final prompt = engine.multiClarificationPrompt(merged);
        if (prompt == null) {
          pendingBatch = null;
          return _saveBatch(merged);
        }
        pendingBatch = merged;
        return R3Reply('ask_multi', prompt);
      }
      pendingBatch = null;
    }

    final cmd = assistant.handleCommand(text, hasPendingDraft: active != null && !active!.isComplete);
    if (cmd != null && cmd.rewrittenInput != null) {
      text = cmd.rewrittenInput!;
    } else if (cmd != null) {
      _sync(cmd);
      active = null;
      return R3Reply(cmd.route, cmd.text);
    }

    final lower = text.toLowerCase();
    if (last != null &&
        (active == null || active!.isComplete) &&
        last!.isRecurrent &&
        RegExp(r'dia\s+[uú]til|\b(?:todo|vence(?:\s+no)?|cai(?:\s+no)?)\s+dia\s+\d').hasMatch(lower) &&
        !RegExp(r'\d+(?:[.,]\d+)?\s*(?:reais|real)|r\$').hasMatch(lower)) {
      final updated = engine.applyCorrection(last!, text);
      last = updated.isCanceled ? null : updated;
      final before = repo.transactions.where((t) => lastIds.contains(t.id)).toList();
      if (!updated.isCanceled) assistant.recordExternalEdit(before);
      for (final id in lastIds) {
        if (updated.isCanceled) {
          repo.deleteTransaction(id);
        } else {
          repo.applyDraftCorrection(id, updated);
        }
      }
      if (updated.isCanceled) lastIds = const [];
      return R3Reply(updated.isCanceled ? 'correction_cancel' : 'correction', updated.clarificationPrompt ?? 'Lançamento atualizado com sucesso!', updated);
    }

    String? preface;
    final debt = DebtPaymentParser.parse(text);
    if (debt != null) {
      final matches = repo.findDebtorsByName(debt.personName);
      if (matches.isEmpty) {
        preface = DebtPaymentParser.noOpenDebtNote(debt.personName);
      } else if (matches.length == 1) {
        final res = repo.applyDebtPayment(matches.first.id, debt.amountPaid);
        return R3Reply('debt', '${debt.personName} pagou ${res.amountPaid}; resta ${res.remainingBalance}');
      } else {
        return R3Reply('debt', 'ambíguo: ${debt.personName}');
      }
    }

    final goalCreation = GoalParser.parseCreation(text);
    if (goalCreation != null) {
      repo.addGoal(FinancialGoal(id: 'goal-b-${++_goalSeq}', title: goalCreation.title, targetAmount: goalCreation.targetAmount, targetDate: goalCreation.targetDate));
      return R3Reply('goal_create', 'Meta criada: "${goalCreation.title}" ${goalCreation.targetAmount}');
    }
    final goalContribution = GoalParser.parseContribution(text);
    if (goalContribution != null) {
      final matches = repo.findGoalsByTitle(goalContribution.goalTitle);
      if (matches.length == 1) {
        final g = repo.contributeToGoal(matches.first.id, goalContribution.amount);
        return R3Reply('goal_contrib_legacy', '"${g.title}" ${g.savedAmount}/${g.targetAmount}');
      }
      return R3Reply('goal_contrib_legacy', 'meta não encontrada: "${goalContribution.goalTitle}"');
    }

    final afford = AffordabilityAnalyzer(repository: repo).analyze(text);
    if (afford != null) return R3Reply('afford:${afford.verdict.name}', afford.formattedText);

    final answer = assistant.handleQuestion(text);
    if (answer != null) {
      _sync(answer);
      active = null;
      return R3Reply(answer.route, answer.text);
    }

    if (active == null || active!.isComplete) {
      final multi = engine.parseMulti(text);
      if (multi.length >= 2) {
        final prompt = engine.multiClarificationPrompt(multi);
        if (prompt == null) return _saveBatch(multi);
        pendingBatch = multi;
        active = null;
        return R3Reply('ask_multi', prompt);
      }
    }

    FinancialTransactionDraft draft;
    var merged = false;
    String? discardedNotice;
    if (active != null && !active!.isComplete && !engine.startsNewTransaction(active!, text)) {
      draft = engine.mergeDrafts(active!, text);
      merged = true;
    } else {
      if (active != null && !active!.isComplete) discardedNotice = LocalFinancialNlpEngine.discardedDraftNotice(active!);
      draft = engine.parse(text);
    }
    if (draft.isComplete) draft = repo.applyCategoryMemory(draft);

    var route = draft.isComplete ? 'saved' : 'ask';
    var responseText = draft.clarificationPrompt ?? 'Lançamento registrado: ${draft.amount} ${draft.description} ${draft.category} ${draft.paymentMethod}';
    if (draft.isComplete && !merged && draft.assumptionNote != null) responseText = '$responseText ${draft.assumptionNote}';
    if (draft.isComplete && draft.budgetInsight != null) responseText = '$responseText ${draft.budgetInsight}';
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      _saved(repo.addTransactionFromDraft(draft).map((t) => t.id).toList());
      if (draft.isReminder) {
        repo.addReminder(FinancialReminder(
          id: 'rem-b-${repo.reminders.length + 1}-${DateTime.now().microsecondsSinceEpoch}',
          title: draft.description,
          personName: draft.personName,
          amount: draft.amount,
          targetDate: draft.targetDate ?? DateTime.now().add(const Duration(days: 30)),
          type: draft.reminderType == 'loan_receivable'
              ? ReminderType.loanReceivable
              : (draft.reminderType == 'dividend' ? ReminderType.dividend : ReminderType.general),
        ));
      }
      last = draft;
      active = null;
    } else if (!draft.isComplete) {
      active = draft;
    }
    if (draft.intent == 'query') {
      route = 'query';
      responseText = engine.replyForQuestion(draft);
      active = null;
    } else if (draft.intent == 'unknown' && !merged) {
      route = 'unknown';
      active = null;
    }
    if (preface != null) responseText = '$preface\n\n$responseText';
    if (discardedNotice != null) responseText = '$discardedNotice\n\n$responseText';
    return R3Reply(route, responseText, draft);
  }

  R3Reply _saveBatch(List<FinancialTransactionDraft> drafts) {
    for (final d in drafts) {
      _saved(repo.addTransactionFromDraft(d).map((t) => t.id).toList());
    }
    last = drafts.last;
    return R3Reply('multi', 'Identifiquei ${drafts.length} lançamentos: ${drafts.map((d) => '${d.amount} ${d.description}').join('; ')}');
  }
}

// ───────────────────────── fixtures (títulos NOVOS) ─────────────────────────
// Hoje = qua 30/09/2026 → ontem ter 29/09, seg 28/09, dom 27/09, sáb 26/09,
// sex 25/09, qui 24/09.

List<FinancialTransaction> fixtures([DateTime? now]) {
  final t = _day(now ?? today);
  FinancialTransaction f(String id, String title, double amount, String cat, DateTime d, {TransactionType type = TransactionType.expense}) =>
      FinancialTransaction(id: id, title: title, amount: amount, type: type, category: cat, paymentMethod: 'pix', date: d.add(const Duration(hours: 12)));
  return [
    f('fx-cafe-amanha', 'Café Amanhã', 18, 'leisure', back(1, t)),
    f('fx-bar-dia15', 'Bar Dia 15', 64, 'leisure', back(1, t)),
    f('fx-mercado-dad', 'Mercado Dia a Dia', 132, 'supermarket', back(1, t)),
    f('fx-lanchonete-qa', 'Lanchonete Quinta Avenida', 27, 'leisure', wdLast(1, t)),
    f('fx-posto-shell', 'Posto Shell', 180, 'transport', wdLast(1, t)),
    f('fx-99', '99', 23, 'transport', wdLast(1, t)),
    f('fx-horti-tv', 'Hortifruti Terça Verde', 41, 'supermarket', wdLast(7, t)),
    f('fx-loja-25', 'Loja 25 de Março', 95, 'expense_other', wdLast(6, t)),
    f('fx-acougue', 'Açougue', 77, 'supermarket', wdLast(5, t)),
    f('fx-drogaria-dom', 'Drogaria Domingo', 52, 'health', wdLast(4, t)),
    f('fx-sacolao', 'Sacolão', 38, 'supermarket', back(8, t)),
    f('fx-estac', 'Estacionamento Centro', 15, 'transport', wdLast(7, t)),
    f('fx-aluguel', 'Aluguel', 1400, 'housing', back(25, t)),
    f('fx-bico', 'Bico de pintura', 400, 'income_other', back(3, t), type: TransactionType.income),
  ];
}

Future<FinancialRepository> freshRepo([DateTime? now]) async {
  SharedPreferences.setMockInitialValues({});
  final repo = FinancialRepository();
  await repo.initialize();
  for (final t in fixtures(now)) {
    repo.addTransaction(t);
  }
  repo.addGoal(FinancialGoal(id: 'g-moto', title: 'Moto', targetAmount: 9000, savedAmount: 1200));
  repo.addGoal(FinancialGoal(id: 'g-reserva', title: 'Reserva', targetAmount: 3000));
  repo.addReminder(FinancialReminder(
      id: 'rem-carla', title: 'Carla me deve', personName: 'Carla', amount: 350, targetDate: today.add(const Duration(days: 15)), type: ReminderType.loanReceivable));
  return repo;
}

Map<String, String> remSnap(FinancialRepository r) => {for (final x in r.reminders) x.id: '${x.amount}|${x.isCompleted}'};

// ───────────────────────── oráculo de datas ─────────────────────────

class DateFrag {
  final String text;
  final DateTime? exp;
  final bool ask;
  final Set<DateTime> alt;
  final bool vague;
  DateFrag(this.text, this.exp, {this.ask = false, this.alt = const {}, this.vague = false});
}

const _wdNames = {1: 'segunda', 2: 'terça', 3: 'quarta', 4: 'quinta', 5: 'sexta', 6: 'sábado', 7: 'domingo'};
const _monthNames = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
const _extenso = {2: 'dois', 3: 'três', 4: 'quatro', 5: 'cinco', 6: 'seis', 7: 'sete', 8: 'oito', 10: 'dez'};

T pickOf<T>(Random rng, List<T> l) => l[rng.nextInt(l.length)];

/// [leading]: o fragmento vai no começo da frase (formas que pedem "que").
DateFrag dateFrag(Random rng, DateTime now, {bool leading = false}) {
  final t = _day(now);
  final r = rng.nextInt(100);
  if (r < 8) return DateFrag(pickOf(rng, ['ontem à noite', 'ontem de manhã', 'ontem cedo', 'ontem']), back(1, t));
  if (r < 13) return DateFrag(pickOf(rng, ['anteontem', 'antes de ontem', 'anteontem à tarde']), back(2, t));
  if (r < 23) {
    final n = pickOf(rng, [2, 3, 4, 5, 6, 10]);
    final w = _extenso[n]!;
    final form = rng.nextInt(4);
    if (form == 0) return DateFrag('há $w dias', back(n, t));
    if (form == 1) return DateFrag('faz $w dias', back(n, t));
    if (form == 2) return DateFrag(leading ? 'tem $w dias que' : 'uns $w dias atrás', back(n, t));
    return DateFrag('$w dias atrás', back(n, t));
  }
  if (r < 37) {
    final wd = 1 + rng.nextInt(7);
    final name = _wdNames[wd]!;
    final last = wdLast(wd, t);
    final sameDay = wd == t.weekday;
    final form = rng.nextInt(5);
    final g = wd >= 6 ? 'o' : 'a';
    if (form == 0 && wd <= 5) return DateFrag('na $name-feira passada', last);
    if (form == 1) return DateFrag('$name retrasad$g', DateTime(last.year, last.month, last.day - 7));
    if (form == 2) return DateFrag('n$g $name passad$g', last);
    if (form == 3 && wd <= 5) return DateFrag('$name-feira', last, alt: sameDay ? {t} : const {});
    return DateFrag('n$g $name', last, alt: sameDay ? {t} : const {});
  }
  if (r < 50) {
    final n = rng.nextInt(12) == 0 ? pickOf(rng, [0, 33, 31]) : 1 + rng.nextInt(30);
    final d = diaN(n, t);
    final form = rng.nextInt(4);
    final txt = form == 0 ? 'dia $n' : (form == 1 ? 'no dia $n' : (form == 2 && n == 1 ? 'dia 1º' : 'no dia $n'));
    return DateFrag(txt, d, ask: d == null);
  }
  if (r < 62) {
    // dd/mm SEMPRE com contexto de data ("em", "dia", "no dia").
    final dd = 1 + rng.nextInt(31), mm = rng.nextInt(14) == 0 ? 13 : 1 + rng.nextInt(12);
    final txt = '${rng.nextBool() ? dd.toString().padLeft(2, '0') : dd}/${rng.nextBool() ? mm.toString().padLeft(2, '0') : mm}';
    final o = ddmmOracle(dd, mm, t);
    return DateFrag('${pickOf(rng, ['em', 'dia', 'no dia'])} $txt', o.date, ask: o.ask);
  }
  if (r < 68) {
    final dd = 1 + rng.nextInt(28), mm = 1 + rng.nextInt(12);
    final o = ddmmOracle(dd, mm, t);
    return DateFrag('${pickOf(rng, ['em ', 'no dia ', ''])}$dd de ${_monthNames[mm - 1]}', o.date, ask: o.ask);
  }
  if (r < 74) {
    final n = 1 + rng.nextInt(28);
    final first = DateTime(t.year, t.month - 1, 1);
    final ok = n <= _daysIn(first.year, first.month);
    return DateFrag('dia $n do mês passado', ok ? DateTime(first.year, first.month, n) : null, ask: !ok);
  }
  if (r < 81) {
    return DateFrag(pickOf(rng, ['amanhã', 'depois de amanhã', 'sexta que vem', 'daqui a 3 dias', 'semana que vem', 'mês que vem', 'na próxima segunda']), null,
        ask: true);
  }
  if (r < 86) {
    return DateFrag(pickOf(rng, ['mês passado', 'mês retrasado', 'semana retrasada', 'há duas semanas', 'três meses atrás']), null, ask: true);
  }
  if (r < 91) {
    return DateFrag(pickOf(rng, ['semana passada', 'esses dias', 'outro dia', 'no começo do mês']), null, vague: true);
  }
  return DateFrag(pickOf(rng, ['hoje', 'hoje cedo', 'hj', 'agora há pouco', 'hoje de manhã']), t);
}

// ───────────────────────── gerador ─────────────────────────

class GenB {
  final Random rng;
  final int length;
  GenB(this.rng, this.length);
  int _n = 0;
  final List<LT> _q = [];

  T pick<T>(List<T> l) => l[rng.nextInt(l.length)];
  static const _amts = [9, 14, 23, 37, 47, 58, 66, 85, 118, 175, 260, 1350];
  int amt() => pick(_amts);
  List<int> distinctAmts(int k) {
    final s = <int>{};
    while (s.length < k) {
      s.add(amt());
    }
    return s.toList();
  }

  static const _places = [' no sacolão', ' na lotérica', ' no chaveiro', ' na papelaria', ' no petshop', ' na barbearia', ' no estacionamento', ' na banca'];
  static const _pays = [' no pix', ' no débito', ' no dinheiro', ' no crédito à vista', ''];

  /// Palavra de data só no NOME do lugar / endereço: a frase não diz data.
  /// [proper]: nome próprio com maiúscula/endereço (lido como data = P0);
  /// senão minúscula ambígua (lido como data com aviso = P2).
  static const _titlePlaces = <List<Object>>[
    [' no Café Amanhã', true],
    [' na Lanchonete Quinta Avenida', true],
    [' no Hortifruti Terça Verde', true],
    [' na Loja 25 de Março', true],
    [' no Bar Dia 15', true],
    [' no Mercado Dia a Dia', true],
    [' na Drogaria Domingo', true],
    [' no Restaurante Sexta-Feira 13', true],
    [' na Sorveteria Sábado Feliz', true],
    [' na rua 25 de março', true],
    [' na avenida 7 de setembro', true],
    [' na praça 15 de novembro', true],
    [' na rua 13 de maio', true],
    [' no bar até amanhã', false],
    [' na padaria pão de hoje', true],
    [' no açougue domingo', false],
  ];

  /// [texto com {A}/{P}, direção, óbvia?, pergunta aceitável?]
  static const _cores = <List<Object>>[
    // entradas óbvias
    ['recebi {A} do aluguel da kitnet{P}', 'income', true, false],
    ['o inquilino me pagou {A}{P}', 'income', true, false],
    ['a cliente me transferiu {A}{P}', 'income', true, false],
    ['minha tia me deu {A} de aniversário{P}', 'income', true, false],
    ['vendi meu videogame por {A}{P}', 'income', true, false],
    ['vendemos o fogão velho por {A}{P}', 'income', true, false],
    ['faturei {A} com as encomendas de bolo{P}', 'income', true, false],
    ['caiu {A} da restituição do imposto{P}', 'income', true, false],
    ['o cliente pagou {A} pelo conserto{P}', 'income', true, false],
    ['me pagaram {A} pela diária de pedreiro{P}', 'income', true, false],
    ['o banco me estornou {A}{P}', 'income', true, false],
    ['meu irmão me devolveu {A}{P}', 'income', true, false],
    ['ganhei {A} num sorteio{P}', 'income', true, false],
    ['entrou {A} de comissão{P}', 'income', true, false],
    ['fiz uma venda de {A}{P}', 'income', true, false],
    ['fechei uma venda de {A}{P}', 'income', true, false],
    ['cobrei {A} do cliente{P}', 'income', true, false],
    ['cobrei a consulta de {A} do paciente{P}', 'income', true, false],
    ['o cliente pagou a fatura de {A}{P}', 'income', true, true],
    // entradas onde perguntar é aceitável (despesa nunca)
    ['herdei {A} da minha avó{P}', 'income', false, true],
    ['resgatei {A} da poupança{P}', 'income', false, true],
    ['arrecadei {A} na rifa{P}', 'income', false, true],
    ['tirei {A} vendendo trufa{P}', 'income', false, true],
    // saídas óbvias
    ['paguei {A} pro encanador{P}', 'expense', true, false],
    ['gastei {A} com a festa da firma{P}', 'expense', true, false],
    ['o síndico me cobrou {A} de multa{P}', 'expense', true, false],
    ['me mandaram pagar {A} de taxa de lixo{P}', 'expense', true, false],
    ['me fizeram desembolsar {A} pela vistoria{P}', 'expense', true, false],
    ['a escola me obrigou a comprar {A} de material{P}', 'expense', true, false],
    ['recebi a fatura do cartão de {A}', 'expense', true, false],
    ['chegou o boleto da faculdade de {A}', 'expense', true, false],
    ['veio a conta de água de {A}', 'expense', true, false],
    ['ganhei uma multa de {A} por excesso de velocidade', 'expense', true, false],
    ['devolvi {A} pro joão{P}', 'expense', true, false],
    ['repassei {A} pra minha mãe{P}', 'expense', true, false],
    ['enviei {A} pro meu filho{P}', 'expense', true, false],
    ['adiantei {A} pro pedreiro{P}', 'expense', true, false],
    ['banquei o jantar de {A}{P}', 'expense', true, false],
    ['o joão me vendeu a bicicleta dele por {A}{P}', 'expense', false, true],
    ['comprei a geladeira que a vizinha vendeu por {A}{P}', 'expense', true, false],
    ['vendi o carro e paguei {A} de despachante{P}', 'expense', false, true],
    ['acertei {A} com o mecânico{P}', 'expense', false, true],
  ];

  LT next(FinancialRepository repo) {
    _n++;
    if (_q.isNotEmpty) return _q.removeAt(0);
    if (_n > length) return LT('⟲fim', 'fim');
    final r = rng.nextInt(1000);
    if (r < 150) return _valuelessPair();
    if (r < 300) return _launch();
    if (r < 420) return _values();
    if (r < 520) return _multi();
    if (r < 650) return _hypothesis();
    if (r < 790) return _editDelete();
    if (r < 830) return _recurrence();
    return _noise();
  }

  LT _launch({bool allowTitle = true}) {
    final core = pick(_cores);
    final tmpl = core[0] as String;
    final a = amt();
    final useTitle = allowTitle && rng.nextInt(4) == 0;
    final tp = pick(_titlePlaces);
    final place = useTitle ? tp[0] as String : (rng.nextInt(3) == 0 ? pick(_places) : '');
    var body = tmpl.replaceAll('{A}', '$a').replaceAll('{P}', tmpl.contains('{P}') ? place : '');
    if (!tmpl.contains('{P}') && useTitle) body = '$body$place';
    final pay = (tmpl.contains('{P}') || rng.nextBool()) ? pick(_pays) : '';
    final d = rng.nextInt(3) == 0 ? null : dateFrag(rng, today, leading: true);
    String text;
    if (d == null) {
      text = '$body$pay';
    } else {
      final pos = rng.nextInt(3);
      if (pos == 0) {
        text = '${d.text} $body$pay';
      } else if (pos == 1) {
        final i = body.indexOf('$a') + '$a'.length;
        final frag = d.text.endsWith(' que') ? d.text.substring(0, d.text.length - 4) : d.text;
        text = '${body.substring(0, i)} $frag${body.substring(i)}$pay';
      } else {
        final frag = d.text.endsWith(' que') ? d.text.substring(0, d.text.length - 4) : d.text;
        text = '$body$pay $frag';
      }
      // "tem N dias" só é data com "que" logo depois — fora do começo vira "uns N dias atrás".
      text = text.replaceAllMapped(RegExp(r'(?<!^)\btem (\w+) dias\b(?! que)'), (m) => 'uns ${m.group(1)} dias atrás');
    }
    final lt = LT(text, useTitle ? 'lançar-título' : 'lançar')
      ..dir = core[1] as String
      ..obviousDir = core[2] as bool
      ..dirAskOk = core[3] as bool
      ..single = a.toDouble();
    if (d == null) {
      lt.expDate = today;
      lt.titleDate = useTitle;
      if (useTitle && !(tp[1] as bool)) lt.family = 'lançar-título-ambíguo';
    } else {
      lt.expDate = d.exp;
      lt.expAlt = d.alt;
      lt.mustAsk = d.ask;
      lt.vagueDate = d.vague;
      if (d.vague) lt.expDate = null;
    }
    return lt;
  }

  /// Frase de UM valor com números que não são dinheiro (e o contrário).
  LT _values() {
    final a = amt();
    final t = pick(<List<Object>>[
      ['comprei um iphone 13 por $a no pix', a],
      ['paguei $a no pneu aro 14 no pix', a],
      ['comprei uma tv de 50 polegadas por $a no pix', a],
      ['comprei 2 pão de queijo por $a no pix', a],
      ['peguei 3 cerveja por $a no pix', a],
      ['gastei $a na loja 12 do shopping no pix', a],
      ['gastei $a no mercado da rua 7 com a minha mãe no pix', a],
      ['paguei $a no estacionamento das 14 às 18 no pix', a],
      ['gastei $a no bar lá pelas 23h no pix', a],
      ['paguei $a de pedágio no km 32 no pix', a],
      ['comprei um tênis tamanho 42 por $a no pix', a],
      ['paguei $a na conta com 10% de serviço no pix', a],
      ['comprei 1 dúzia de ovos por $a no pix', a],
      ['gastei $a no presente do meu sobrinho de 5 anos no pix', a],
      ['paguei a 2ª parcela de $a do sofá no pix', a],
      ['paguei o ipva 2026 de $a no pix', a],
      ['gastei $a no rodízio pra 4 pessoas no pix', a],
      ['comprei a camisa 10 do flamengo por $a no pix', a],
      ['gastei $a na farmácia do bloco 3 no pix', a],
      ['paguei $a por 2 horas de estacionamento no pix', a],
      ['comprei 300g de presunto por $a no pix', a],
      ['gastei $a,50 no sacolão no pix', a + 0.5],
      ['paguei R\$ $a,00 de luz no pix', a],
      ['gastei 1.${(a % 900 + 100).toString().padLeft(3, '0')} no material de obra no pix', 1000.0 + (a % 900 + 100)],
      ['peguei a linha 8012 e paguei $a no cartão de débito', a],
      ['gastei $a no sacolão às 7 da manhã no pix', a],
      ['gastei $a na papelaria, 3 cadernos e 2 canetas, no pix', a],
      ['paguei $a na revisão dos 10 mil km no pix', a],
      ['paguei $a no corte de cabelo, nota 10, no pix', a],
      ['gastei $a com o kit 5 em 1 no pix', a],
      // "d/m" sem contexto de data: contagem, placar, tamanho — não é data
      ['paguei $a na aula 5/8 do curso no pix', a, true],
      ['gastei $a na sessão 4/6 do pilates no pix', a, true],
      ['paguei $a na rodada 3/5 do bolão no pix', a, true],
      ['o jogo terminou 3/1 e gastei $a no bar no pix', a, true],
      ['comprei um tênis 40/41 por $a no pix', a, true],
      ['paguei $a no plantão 12/12 do hospital no pix', a, true],
      ['gastei $a no Restaurante Sexta-Feira 13 no pix', a, true],
      ['gastei $a na Loja 25 de Março no pix', a, true],
    ]);
    return LT(t[0] as String, 'um-valor')
      ..dir = 'expense'
      ..single = (t[1] as num).toDouble()
      ..oneValueOnly = true
      ..titleDate = t.length > 2
      ..expDate = today;
  }

  LT _multi() {
    final r = rng.nextInt(100);
    final ab = distinctAmts(2);
    final a = ab[0], b = ab[1];
    if (r < 50) {
      final sepT = pick(<String>[
        'gastei $a no açougue / $b na padaria',
        'gastei $a no açougue + $b na padaria',
        'gastei $a no açougue | $b na padaria',
        'gastei $a no açougue, daí $b na padaria',
        'gastei $a no açougue e depois $b na padaria',
        'gastei $a no açougue além de $b na padaria',
        'gastei $a no açougue fora os $b da padaria',
        'gastei $a no açougue sem contar os $b da padaria',
        'açougue $a; padaria $b',
        'açougue: $a, padaria: $b',
        '$a açougue $b padaria',
        'deixei $a no salão e $b na manicure',
        'gastei $a no açougue mais $b na padaria',
        'gastei $a no açougue e mais $b na padaria',
        'gastei $a no açougue, também $b na padaria',
        'gastei $a no açougue aí $b na padaria',
        'paguei $a de entrada e $b de frete',
        'gastei $a no açougue\n$b na padaria',
        'torrei $a no açougue e $b na padaria e $a no chaveiro',
      ]);
      var text = '$sepT${pick(_pays)}';
      var vals = RegExp(r'\b\d+\b').allMatches(sepT).map((m) => double.parse(m.group(0)!)).toList();
      DateTime? exp = today;
      var ask = false;
      if (rng.nextInt(3) == 0) {
        final d = dateFrag(rng, today);
        final pos = rng.nextInt(3);
        final frag = d.text.endsWith(' que') ? d.text.substring(0, d.text.length - 4) : d.text;
        if (pos == 0) {
          text = '$frag: $text';
        } else if (pos == 1) {
          text = '$text, tudo $frag';
        } else {
          text = '$text $frag';
        }
        exp = d.vague ? null : d.exp;
        ask = d.ask;
      }
      return LT(text, 'multi-sep')
        ..dir = 'expense'
        ..values = vals
        ..expDate = exp
        ..mustAsk = ask;
    }
    if (r < 75) {
      // data por item
      final dd = pick(<List<Object>>[
        ['ontem gastei $a no chaveiro e hoje $b na banca no pix', back(1), today],
        ['anteontem $a no chaveiro e ontem $b na banca, no pix', back(2), back(1)],
        ['gastei $a no chaveiro na segunda e $b na banca na terça no pix', wdLast(1), wdLast(2)],
        ['no domingo $a no petshop e hoje $b na lotérica, tudo no pix', wdLast(7), today],
      ]);
      return LT(dd[0] as String, 'multi-data-item')
        ..dir = 'expense'
        ..values = [a.toDouble(), b.toDouble()]
        ..valueDate = {a.toDouble(): dd[1] as DateTime, b.toDouble(): dd[2] as DateTime};
    }
    final m = pick(<List<Object>>[
      ['recebi $a do bico e torrei $b no bar no pix', {a.toDouble(): 'income', b.toDouble(): 'expense'}],
      ['vendi o fogão por $a e comprei um micro-ondas de $b no pix', {a.toDouble(): 'income', b.toDouble(): 'expense'}],
      ['me pagaram $a da faxina e gastei $b no sacolão no pix', {a.toDouble(): 'income', b.toDouble(): 'expense'}],
      ['paguei $a de luz e o inquilino me pagou $b no pix', {a.toDouble(): 'expense', b.toDouble(): 'income'}],
      ['paguei $a no açougue e $a na padaria no pix', <double, String>{}],
      ['paguei $a de academia e $a de inglês no pix', <double, String>{}],
      ['gastei $a com o veterinário $b com a ração no pix', <double, String>{}],
      ['recebi $a do joão e $b da carla no pix', <double, String>{}],
    ]);
    final text = m[0] as String;
    final vd = m[1] as Map<double, String>;
    final lt = LT(text, 'multi-misto')
      ..values = RegExp(r'\b\d+\b').allMatches(text).map((x) => double.parse(x.group(0)!)).toList()
      ..valueDir = vd
      ..expDate = today;
    if (vd.isEmpty) lt.dir = text.startsWith('recebi') ? 'income' : 'expense';
    return lt;
  }

  LT _hypothesis() {
    final a = amt();
    final r = rng.nextInt(100);
    if (r < 55) {
      final t = pick(<String>[
        'no caso de eu gastar $a no mercado no pix',
        'em caso de eu pagar $a de multa no pix',
        'faz de conta que gastei $a no shopping no pix',
        'pretendo gastar $a no sacolão no pix',
        'to pensando em comprar um tênis de $a no pix',
        'tô planejando gastar $a na viagem no pix',
        'quero comprar uma bike de $a no pix',
        'vou gastar uns $a no mercado no pix',
        'se acaso eu precisar pagar $a de conserto',
        'caso venha uma conta de $a, pago no pix',
        'se rolar uma promoção, gasto $a no pix',
        'se der certo, ganho $a de comissão',
        'imaginando que eu pague $a de luz no pix',
        'e caso eu gaste $a no mercado?',
        'qual seria meu saldo se eu gastasse $a?',
        'e se a luz vier $a?',
        'se o aluguel subir pra $a, ainda sobra?',
        'se minha esposa gastar $a no shopping no pix',
        'quando eu receber os $a do freela, pago o cartão',
        'assim que cair $a de salário eu pago o aluguel',
        'depois que eu vender a bike por $a, compro outra',
        'se a carla me devolver $a, guardo na reserva',
        'se eu juntar $a por mês, quando chego na moto?',
        'caso o cliente me pague $a, entra no pix',
        'se por acaso o conserto sair $a no pix',
        'na eventualidade de eu gastar $a no pix',
        'hipoteticamente, $a no mercado no pix',
        'se o 99 cobrar $a, compensa?',
        'se eu for na feira sábado e gastar $a',
        'caso a gasolina custe $a, abasteço no débito',
      ]);
      if (rng.nextInt(3) == 0) {
        _q.add(LT(pick(['no pix', 'no débito', 'sacolão', 'isso', 'pode ser']), 'hipótese-cont')..hyp = true);
      }
      return LT(t, 'hipótese')..hyp = true;
    }
    if (r < 70) {
      final t = pick(<String>[
        'quase gastei $a no shopping no pix',
        'ia comprar um fone de $a mas desisti',
        'desisti de comprar o tênis de $a',
        'não gastei os $a que tinha separado pro bar',
        'ainda não paguei os $a da luz',
        'nem cheguei a pagar os $a do conserto',
        'cancelei a compra de $a no pix',
        'por pouco não torrei $a no cassino',
      ]);
      return LT(t, 'não-aconteceu')
        ..hyp = true
        ..notHappened = true;
    }
    final t = pick(<List<Object>>[
      ['acabei de pagar $a no sacolão no pix, se precisar te mando o comprovante', 'expense', a],
      ['acabei de gastar $a na papelaria no pix', 'expense', a],
      ['a conta do bar ficou em $a no pix, se quiser divido com vc', 'expense', a],
      ['tive um gasto de $a com remédio no pix, se for preciso guardo a nota', 'expense', a],
      ['saíram $a da conta pro mecânico, se eu achar a nota te mando', 'expense', a],
      ['hoje rolou um gasto de $a no petshop no pix, caso queira saber', 'expense', a],
      ['fui no dentista e saiu $a no débito, se precisar volto lá', 'expense', a],
      ['gastei $a no salão no pix, se bem que valeu a pena', 'expense', a],
      ['paguei $a de condomínio no pix, se não me falha a memória', 'expense', a],
      ['botei $a de gasolina no débito, caso o tanque estivesse vazio', 'expense', a],
      ['recebi $a da carla no pix, se ela pagar o resto te aviso', 'income', a],
      ['a pizza custou $a no pix, se sobrar eu levo amanhã pro trabalho', 'expense', a],
      ['paguei $a no chaveiro no pix pra ver se a porta abria', 'expense', a],
      ['comprei um vestido de $a no pix caso tenha festa', 'expense', a],
      ['o cliente me pagou $a no pix, se quiser confere no extrato', 'income', a],
    ]);
    return LT(t[0] as String, 'fato-com-se')
      ..hyp = false
      ..dir = t[1] as String
      ..single = (t[2] as int).toDouble()
      ..expDate = today;
  }

  LT _valuelessPair() {
    final p = pick(<List<String?>>[
      ['paguei o chaveiro no pix', 'expense', 'chaveiro'],
      ['comprei ração pro cachorro no pix', 'expense', 'racao'],
      ['gastei no sacolão no pix', 'expense', 'sacolao'],
      ['paguei a manicure no débito', 'expense', 'manicure'],
      ['gastei com o veterinário no pix', 'expense', 'veterinario'],
      ['o inquilino me pagou no pix', 'income', 'inquilino'],
      ['recebi o acerto do bico no pix', 'income', 'bico'],
      ['paguei a lanchonete quinta avenida no pix', 'expense', 'lanchonete'],
      ['gastei no Café Amanhã no pix', 'expense', 'cafe'],
    ]);
    final pend = LT(p[0]!, 'rascunho')..dir = p[1];
    final oldWord = p[2]!;
    final pendTitleDate = oldWord == 'lanchonete' || oldWord == 'cafe';
    final r = rng.nextInt(100);
    final a = amt();
    final b = distinctAmts(2).firstWhere((x) => x != a, orElse: () => a + 7);
    if (r < 40) {
      final f = pick(<List<Object?>>[
        ['$a', null],
        ['deu $a certinho', null],
        ['foram $a', null],
        ['$a pila', null],
        ['R\$$a', null],
        ['foi uns $a', null],
        ['$a reais', null],
        ['paguei $a', null],
        ['custou $a', null],
        ['$a,90', 0.9],
        ['deu $a ontem à noite', -1],
        ['foi $a há dois dias', -2],
        ['$a anteontem', -2],
        ['foi $a na segunda-feira', 'seg'],
        ['foi $a no domingo', 'dom'],
        ['foi $a no dia 28', 'd28'],
        ['$a dia 1º', 'd1'],
        ['$a semana passada', 'vague'],
        ['foi $a amanhã', 'ask'],
        ['$a dia 15/11', 'ask'],
      ]);
      final lt = LT(f[0] as String, 'resposta')
        ..pendingAnswer = true
        ..dir = p[1]
        ..single = a.toDouble()
        ..expDate = today;
      final k = f[1];
      if (k == 0.9) lt.single = a + 0.9;
      if (k is int) lt.expDate = back(-k);
      if (k == 'seg') lt.expDate = wdLast(1);
      if (k == 'dom') lt.expDate = wdLast(7);
      if (k == 'd28') lt.expDate = diaN(28);
      if (k == 'd1') lt.expDate = diaN(1);
      if (k == 'vague') {
        lt.expDate = null;
        lt.vagueDate = true;
      }
      if (k == 'ask') {
        lt.expDate = null;
        lt.mustAsk = true;
      }
      if (pendTitleDate && k == null) lt.titleDate = true;
      _q.add(lt);
    } else if (r < 55) {
      // dois números / autocorreção
      final f = pick(<List<Object>>[
        ['$a ou $b', 'two'],
        ['$a, não, $b', 'fix'],
        ['$a… aliás $b', 'fix'],
        ['foi $a quer dizer $b', 'fix'],
        ['uns $a a $b', 'two'],
        ['$a mais $b de gorjeta', 'two'],
        ['$a pra mim e $b pro joão', 'two'],
        ['$a e pouco', 'approx'],
      ]);
      final lt = LT(f[0] as String, 'resposta-2')..dir = p[1];
      if (f[1] == 'two') lt.values = [a.toDouble(), b.toDouble()];
      if (f[1] == 'fix') {
        lt
          ..single = b.toDouble()
          ..pendingAnswer = true
          ..expDate = today;
      }
      if (f[1] == 'approx') {
        lt
          ..single = a.toDouble()
          ..pendingAnswer = true
          ..expDate = today;
      }
      _q.add(lt);
    } else if (r < 80) {
      // frase nova completa: começa outro lançamento
      final f = pick(<List<String>>[
        ['gastei $a na banca no pix', 'expense', 'banca'],
        ['paguei $a de estacionamento no pix', 'expense', 'estacionamento'],
        ['recebi $a de comissão no pix', 'income', 'comissao'],
        ['comprei um carregador de $a no pix', 'expense', 'carregador'],
        ['tomei um café de $a no pix', 'expense', 'cafe'],
        ['o síndico me cobrou $a de multa no pix', 'expense', 'multa'],
        ['vendi a cadeira por $a no pix', 'income', 'cadeira'],
        ['me devolveram $a no pix', 'income', 'devol'],
      ]);
      final lt = LT(f[0], 'frase-nova')
        ..dir = f[1]
        ..single = a.toDouble()
        ..expDate = today
        ..newWord = f[2]
        ..oldWord = f[2] == oldWord ? null : oldWord;
      _q.add(lt);
    } else if (r < 90) {
      // frase nova SEM valor + o valor dela
      final f = pick(<List<String>>[
        ['paguei a academia', 'expense', 'academia'],
        ['recebi do inquilino', 'income', 'inquilino'],
        ['comprei pão', 'expense', 'pao'],
      ]);
      _q.add(LT(f[0], 'frase-nova-sem-valor'));
      _q.add(LT('$a', 'resposta-da-nova')
        ..pendingAnswer = true
        ..single = a.toDouble()
        ..expDate = today);
    } else {
      _q.add(LT(pick(['sim', 'não sei', 'esquece', 'quanto gastei ontem?', 'e se fosse no débito?', 'isso', 'o mesmo de sempre', '2']), 'rascunho-outro'));
    }
    return pend;
  }

  LT _editDelete() {
    final a = amt();
    final t = pick(<List<Object?>>[
      ['muda o café amanhã pra $a', 'cafe', a],
      ['apaga o café amanhã', 'cafe', null],
      ['muda a lanchonete quinta avenida pra $a', 'lanchonete', a],
      ['muda o hortifruti terça verde pra $a', 'hortifruti', a],
      ['apaga o hortifruti de domingo', 'hortifruti', null],
      ['muda a loja 25 de março pra $a', 'loja', a],
      ['muda o bar dia 15 pra $a', 'bar', a],
      ['muda o mercado dia a dia pra $a', 'mercado', a],
      ['apaga a drogaria domingo', 'drogaria', null],
      ['muda a feira de ontem pra $a', 'feira', a],
      ['muda o uber de segunda pra $a', 'uber', a],
      ['muda a gasolina de segunda pra $a', 'gasolina', a],
      ['muda a comida de segunda pra $a', 'comida', a],
      ['passa o posto shell pra $a', 'posto', a],
      ['passa o açougue de sexta pra $a', 'acougue', a],
      ['passa o 99 pra $a', '99', a],
      ['passa o bico pra $a', 'bico', a],
      ['passa $a pro joão', 'joao', null],
      ['o sacolão foi $a', 'sacolao', a],
      ['na verdade o açougue foi $a', 'acougue', a],
      ['corrige o aluguel pra $a', 'aluguel', a],
      ['apaga o mercado de domingo', 'mercado', null],
      ['exclui o lanche de segunda', 'lanche', null],
      ['muda o café de ontem pra $a', 'cafe', a],
      ['apaga o bar dia 15', 'bar', null],
      ['muda a sorveteria de sábado pra $a', 'sorveteria', a],
      ['apaga a loja do dia 25', 'loja', null],
      ['muda o posto de anteontem pra $a', 'posto', a],
      ['muda o cinema de segunda pra $a', 'cinema', a],
      ['muda a padaria de ontem pra $a', 'padaria', a],
      ['muda o uber de domingo pra $a', 'uber', a],
      ['muda a pizza de ontem pra $a', 'pizza', a],
      ['apaga o cinema de segunda', 'cinema', null],
      ['o táxi de domingo foi $a', 'taxi', a],
    ]);
    final lt = LT(t[0] as String, 'editar-apagar')
      ..named = t[1] as String
      ..editValue = (t[2] as int?)?.toDouble();
    if ((t[0] as String).startsWith('apaga') || (t[0] as String).startsWith('exclui')) {
      if (rng.nextInt(4) > 0) _q.add(LT(pick(['sim', 'esse', 'pode ser', 'isso', 'o primeiro', 'sim', 'não']), 'confirma')..named = t[1] as String);
      if (rng.nextInt(3) == 0) _q.add(LT(pick(['sim', 'pode apagar', 'não']), 'confirma')..named = t[1] as String);
    } else if (rng.nextInt(2) == 0) {
      _q.add(LT(pick(['sim', 'esse', 'pode ser', 'isso mesmo', '1', 'não']), 'confirma')
        ..named = t[1] as String
        ..editValue = (t[2] as int?)?.toDouble());
    }
    return lt;
  }

  LT _recurrence() {
    final a = amt();
    final n = 1 + rng.nextInt(28);
    final t = pick(<List<Object>>[
      ['todo dia $n cai $a da pensão', true],
      ['a mensalidade do curso de $a vence dia $n', true],
      ['pago $a de inglês todo mês no boleto', true],
      ['paguei o curso de inglês dia $n, $a no pix', false],
      ['gastei $a no sacolão dia $n no pix', false],
      ['recebi $a de comissão dia $n no pix', false],
      ['paguei $a de condomínio no pix', false],
    ]);
    return LT(t[0] as String, 'recorrência')..recurrenceOk = t[1] as bool;
  }

  LT _noise() => LT(
      pick([
        'ok', 'blz', 'tá', 'hm', '???', 'esse', 'o primeiro', '47', 'ontem', 'domingo', '15/11', 'se', 'caso', 'quanto?', 'oi césar',
        'obrigado', 'desfaz', 'quanto gastei essa semana?', 'qual meu saldo?', 'cancela', 'e se', 'caso não', 'passa', 'muda pra 50',
      ]),
      'ruído');
}

// ───────────────────────── execução + invariantes ─────────────────────────

const _recWords =
    r'\b(?:todo|toda|todos|todas|mensal|mensalmente|mensalidade|assinatura|assinei|assino|vence|vencimento|cai|sempre|por mes|ao mes|semanal|semanalmente|anual|fixo|fixa|recorrente|pago|recebo|ganho|plano)\b';
const _catRecWords = r'\b(?:aluguel|salario|netflix|spotify|academia|condominio|internet|escola|pensao|curso|ingles)\b';

final _askDirRe = RegExp(r'entrou\*\* pra você|Fiquei na dúvida');
final _askSplitRe = RegExp(r'Vi mais de um valor');
final _askDateRe = RegExp(r'Quando foi esse lançamento|essa data ainda não chegou|Em que dia|não tem dia|não existe dia|não existe|mais de um ano');
final _assumedDateRe = RegExp(r'Considerei (?:a data|o sábado)');

final routeCount = <String, int>{};
final statCount = <String, int>{};
void stat(String k) => statCount[k] = (statCount[k] ?? 0) + 1;

class RunB {
  final List<VA> v;
  final List<LT> sent;
  RunB(this.v, this.sent);
}

Future<RunB> runB(LocalFinancialNlpEngine engine, {List<LT>? fixed, GenB? gen, bool verbose = false}) async {
  final repo = await freshRepo();
  final sim = SimB(engine, repo);
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
    final shortReply = reply.length > 170 ? '${reply.substring(0, 170)}…' : reply;
    void viol(String kind, String detail) => v.add(VA(kind, '"${lt.text}" → [${r.route}] $detail', i));
    if (verbose) print('CHAOS-B|TRACE| ${i + 1}. "${lt.text}" → ${r.short}');

    if (r.text.trim().isEmpty) viol('resposta_vazia', '');
    for (final p in repoInvariants(repo)) {
      viol(p.split(':').first, p);
    }
    final s = CesarText.simplify(lt.text);
    final added = after.tx.keys.where((k) => !before.tx.containsKey(k)).map((k) => jsonDecode(after.tx[k]!) as Map).toList();
    final removed = before.tx.keys.where((k) => !after.tx.containsKey(k)).toList();
    final changed = before.tx.keys.where((k) => after.tx.containsKey(k) && after.tx[k] != before.tx[k]).toList();
    final isUndo = r.route == 'undo';

    // ── nada some sem "sim" / nada muda sem comando ──
    final confirmedDelete = prevRoute == 'confirm_delete' && yesRe.hasMatch(s);
    if (removed.isNotEmpty && !((r.route == 'deleted' && confirmedDelete) || isUndo || r.route == 'correction_cancel')) {
      viol('apagou_sem_sim', 'removeu ${removed.map((k) => describeTx(before.tx[k]!)).take(3).toList()} (antes: [$prevRoute])');
    }
    if (changed.isNotEmpty && !const {'edited', 'undo', 'correction'}.contains(r.route)) {
      viol('mudou_sem_comando', 'mudou ${changed.map((k) => '${describeTx(before.tx[k]!)} ⇒ ${describeTx(after.tx[k]!)}').take(2).toList()}');
    }

    // ── hipótese / intenção / "não aconteceu" nunca grava ──
    if (lt.hyp == true) {
      final goalsChanged = before.goals.toString() != after.goals.toString();
      if (added.isNotEmpty || changed.isNotEmpty || removed.isNotEmpty || goalsChanged || remA.toString() != remB.toString()) {
        viol(lt.notHappened ? 'nao_aconteceu_salvo' : 'hipotese_salva',
            'mudou dados: +${added.map((m) => '${m['title']} ${m['amount']} ${m['type']}').toList()} Δmetas=$goalsChanged Δdívidas=${remA.toString() != remB.toString()} :: $shortReply');
      }
    }
    if (lt.hyp == false && r.route == 'hypothesis') viol('fato_virou_hipotese', shortReply);

    // ── perguntas a mais (P2) ──
    if (lt.obviousDir && _askDirRe.hasMatch(reply) && added.isEmpty) viol('pergunta_direcao_obvia', shortReply);
    if (lt.oneValueOnly && _askSplitRe.hasMatch(reply)) viol('split_a_toa', shortReply);
    if (lt.titleDate && !lt.mustAsk && added.isEmpty && _askDateRe.hasMatch(reply)) viol('data_perguntada_a_toa', shortReply);

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
        if (lt.mustAsk && !rec) viol('data_nao_perguntada', 'salvou $desc (a data dita é futura/inexistente/período)');
        if (lt.vagueDate && !rec) {
          viol(_assumedDateRe.hasMatch(reply) ? 'data_vaga_com_aviso' : 'data_vaga_assumida', 'salvou $desc (data vaga, sem perguntar)');
        }
        final wantDate = lt.valueDate[amount] ?? lt.expDate;
        if (wantDate != null && !rec && date != wantDate && !lt.expAlt.contains(date)) {
          final kind = lt.titleDate
              ? (_assumedDateRe.hasMatch(reply) || lt.family == 'lançar-título-ambíguo' ? 'data_do_titulo_ambigua' : 'data_do_titulo')
              : (plural ? 'data_errada_multi' : 'data_errada');
          viol(kind, 'salvou $desc, esperado ${ddmmyy(wantDate)}');
        }
        if (rec && !RegExp(_recWords).hasMatch(s) && !lt.recurrenceOk) {
          viol(RegExp(_catRecWords).hasMatch(s) ? 'recorrente_por_categoria' : 'recorrente_sem_palavra', 'salvou $desc');
        }
        if (lt.dir != null && !plural && typ != 'transfer' && typ != lt.dir) viol('tipo_trocado', 'frase com sinal de ${lt.dir}, salvou $desc');
        if (lt.single != null && !plural) {
          final ok = (amount - lt.single!).abs() < 0.005 || lt.singleAlt.any((x) => (x - amount).abs() < 0.005);
          if (!ok) viol('valor_trocado', 'esperado ${CesarText.money(lt.single!)}, salvou $desc');
        }
        // frase nova completa fundida no rascunho antigo
        if (lt.newWord != null && lt.oldWord != null) {
          final title = CesarText.fold(m['title'] as String);
          if (title.contains(lt.oldWord!) && !title.contains(lt.newWord!)) viol('frase_nova_fundida', 'salvou $desc no rascunho antigo "${lt.oldWord}"');
        }
      }
      if (lt.values.length >= 2 && added.length < lt.values.length) {
        final amounts = added.map((m) => (m['amount'] as num).toDouble()).toList();
        final missing = [...lt.values];
        for (final a in amounts) {
          final j = missing.indexWhere((x) => (x - a).abs() < 0.005);
          if (j >= 0) missing.removeAt(j);
        }
        viol(added.length == 1 ? 'multi_valor_um_lancamento' : 'multi_valor_parcial',
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
    if (lt.obviousDir && added.isNotEmpty) stat('direcao_obvia_salva');

    // ── edição/exclusão só atinge registro cujo título contém o nome dito ──
    if (lt.named != null && !isUndo) {
      final nm = CesarText.fold(lt.named!);
      bool hasName(String json) => CesarText.fold((jsonDecode(json) as Map)['title'] as String).contains(nm);
      if (r.route == 'edited') {
        for (final k in changed) {
          if (!hasName(before.tx[k]!)) {
            final cat = (jsonDecode(before.tx[k]!) as Map)['category'];
            final shown = prevText.contains((jsonDecode(before.tx[k]!) as Map)['title'] as String) && prevRoute != null && prevRoute != 'edited';
            viol(shown ? 'editou_outro_com_confirmacao' : (CesarText.categoryWords[nm] == cat ? 'editou_por_categoria' : 'editou_sem_nome'),
                'mudou ${describeTx(before.tx[k]!)} ⇒ ${describeTx(after.tx[k]!)} (nome dito "${lt.named}") :: $shortReply');
          } else if (lt.editValue != null) {
            final a0 = ((jsonDecode(before.tx[k]!) as Map)['amount'] as num).toDouble();
            final a1 = ((jsonDecode(after.tx[k]!) as Map)['amount'] as num).toDouble();
            if ((a1 - lt.editValue!).abs() > 0.005 && (a1 - a0).abs() > 0.005) viol('edit_valor_errado', 'pediu ${lt.editValue}, gravou ${describeTx(after.tx[k]!)}');
          }
        }
      }
      if (r.route == 'deleted') {
        for (final k in removed) {
          final title = (jsonDecode(before.tx[k]!) as Map)['title'] as String;
          if (!hasName(before.tx[k]!)) {
            if (prevText.contains(title)) {
              viol('confirmou_outro_nome', 'apagou "$title" (nome dito "${lt.named}"); a confirmação mostrava o item');
            } else {
              viol('apagou_outro', 'apagou "$title", que não estava na confirmação "${prevText.replaceAll('\n', ' ')}"');
            }
          }
        }
      }
      if (prevText.contains('Os mais próximos') && RegExp(r'^(?:sim|esse|pode ser|isso)').hasMatch(s) && RegExp(r'Não consegui identificar').hasMatch(reply)) {
        viol('sugestao_sim_falhou', 'sugestão anterior: "${prevText.replaceAll('\n', ' ')}" :: $shortReply');
      }
    }
    if (lt.named == 'joao' && r.route == 'edited') viol('transferencia_virou_edicao', shortReply);
    prevRoute = r.route;
    prevText = r.text;
  }
  return RunB(v, sent);
}

Future<List<LT>> minimizeB(LocalFinancialNlpEngine engine, List<LT> turns, String kind, Stopwatch sw, int deadlineMs) async {
  Future<bool> fails(List<LT> ts) async => (await runB(engine, fixed: ts)).v.any((x) => x.kind == kind);
  var cur = List<LT>.from(turns);
  final first = (await runB(engine, fixed: cur)).v.where((x) => x.kind == kind).toList();
  if (first.isEmpty) return cur;
  cur = cur.sublist(0, first.first.turn + 1);
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

LT L(String t,
        {String? dir,
        bool obvious = false,
        double? single,
        Set<double> alt = const {},
        List<double> values = const [],
        DateTime? exp,
        Set<DateTime> expAlt = const {},
        bool ask = false,
        bool? hyp,
        bool notHappened = false,
        String? named,
        double? edit,
        bool title = false,
        bool vague = false,
        bool answer = false,
        bool one = false,
        String? newWord,
        String? oldWord,
        Map<double, String> valueDir = const {},
        Map<double, DateTime> valueDate = const {}}) =>
    LT(t, 'alvo')
      ..dir = dir
      ..obviousDir = obvious
      ..single = single
      ..singleAlt = alt
      ..values = values
      ..expDate = exp
      ..expAlt = expAlt
      ..mustAsk = ask
      ..hyp = hyp
      ..notHappened = notHappened
      ..named = named
      ..editValue = edit
      ..titleDate = title
      ..vagueDate = vague
      ..pendingAnswer = answer
      ..oneValueOnly = one
      ..newWord = newWord
      ..oldWord = oldWord
      ..valueDir = valueDir
      ..valueDate = valueDate;

List<List<LT>> targeted() {
  final t = today;
  return [
    // ── A. direção por papel ──
    [L('o inquilino me pagou 1350 no pix', dir: 'income', obvious: true, single: 1350, exp: t)],
    [L('a cliente me transferiu 480 no pix', dir: 'income', obvious: true, single: 480, exp: t)],
    [L('vendi meu videogame por 900 no pix', dir: 'income', obvious: true, single: 900, exp: t)],
    [L('fiz uma venda de 230 no pix', dir: 'income', obvious: true, single: 230, exp: t)],
    [L('fechei uma venda de 1200 no pix', dir: 'income', obvious: true, single: 1200, exp: t)],
    [L('cobrei 150 do cliente no pix', dir: 'income', obvious: true, single: 150, exp: t)],
    [L('o cliente pagou 380 pelo conserto no pix', dir: 'income', obvious: true, single: 380, exp: t)],
    [L('o banco me estornou 59 no pix', dir: 'income', obvious: true, single: 59, exp: t)],
    [L('entrou 640 de comissão no pix', dir: 'income', obvious: true, single: 640, exp: t)],
    [L('caiu 812 da restituição do imposto no pix', dir: 'income', obvious: true, single: 812, exp: t)],
    [L('herdei 5000 da minha avó no pix', dir: 'income', single: 5000, exp: t)],
    [L('resgatei 700 da poupança no pix', dir: 'income', single: 700, exp: t)],
    [L('arrecadei 340 na rifa no pix', dir: 'income', single: 340, exp: t)],
    [L('devolvi 80 pro joão no pix', dir: 'expense', obvious: true, single: 80, exp: t)],
    [L('repassei 300 pra minha mãe no pix', dir: 'expense', obvious: true, single: 300, exp: t)],
    [L('enviei 150 pro meu filho no pix', dir: 'expense', obvious: true, single: 150, exp: t)],
    [L('adiantei 500 pro pedreiro no pix', dir: 'expense', obvious: true, single: 500, exp: t)],
    [L('banquei o jantar de 210 no crédito à vista', dir: 'expense', obvious: true, single: 210, exp: t)],
    [L('o síndico me cobrou 130 de multa no pix', dir: 'expense', obvious: true, single: 130, exp: t)],
    [L('me mandaram pagar 45 de taxa de lixo no pix', dir: 'expense', obvious: true, single: 45, exp: t)],
    [L('me fizeram desembolsar 260 pela vistoria no pix', dir: 'expense', obvious: true, single: 260, exp: t)],
    [L('a escola me obrigou a comprar 180 de material no pix', dir: 'expense', obvious: true, single: 180, exp: t)],
    [L('recebi a fatura do cartão de 1900'), L('no pix', dir: 'expense', single: 1900, exp: t)],
    [L('chegou o boleto da faculdade de 870'), L('no boleto', dir: 'expense', single: 870, exp: t)],
    [L('ganhei uma multa de 195 por excesso de velocidade'), L('no pix', dir: 'expense', single: 195, exp: t)],
    [L('o joão me vendeu a bicicleta dele por 600 no pix', dir: 'expense', single: 600, exp: t)],
    [L('comprei a geladeira que a vizinha vendeu por 900 no pix', dir: 'expense', obvious: true, single: 900, exp: t)],
    [L('vendi o carro e paguei 350 de despachante no pix', dir: 'expense', single: 350, exp: t)],
    [L('ganhei 30 de desconto na farmácia no pix', dir: 'expense')],
    [L('meu pai me pagou a conta de luz de 150', dir: 'expense')],
    [L('recebi 20 de troco no mercado')],
    // ── B. hipóteses novas / intenção / "não aconteceu" ──
    [L('no caso de eu gastar 300 no mercado no pix', hyp: true)],
    [L('em caso de eu pagar 200 de multa no pix', hyp: true)],
    [L('faz de conta que gastei 400 no shopping no pix', hyp: true)],
    [L('pretendo gastar 250 no sacolão no pix', hyp: true)],
    [L('to pensando em comprar um tênis de 320 no pix', hyp: true)],
    [L('quero comprar uma bike de 1500 no pix', hyp: true)],
    [L('vou gastar uns 200 no mercado no pix', hyp: true)],
    [L('se rolar uma promoção, gasto 300 no pix', hyp: true)],
    [L('quando eu receber os 800 do freela, pago o cartão', hyp: true)],
    [L('assim que cair 4500 de salário eu pago o aluguel', hyp: true)],
    [L('depois que eu vender a bike por 900, compro outra', hyp: true)],
    [L('se a carla me devolver 350, guardo na reserva', hyp: true)],
    [L('caso o cliente me pague 900, entra no pix', hyp: true)],
    [L('na eventualidade de eu gastar 600 no pix', hyp: true)],
    [L('hipoteticamente, 250 no mercado no pix', hyp: true)],
    [L('se o 99 cobrar 40, compensa?', hyp: true)],
    [L('se eu for na feira sábado e gastar 90', hyp: true)],
    [L('caso a gasolina custe 6, abasteço no débito', hyp: true)],
    [L('quase gastei 500 no shopping no pix', hyp: true, notHappened: true)],
    [L('ia comprar um fone de 200 mas desisti', hyp: true, notHappened: true)],
    [L('desisti de comprar o tênis de 400', hyp: true, notHappened: true)],
    [L('não gastei os 100 que tinha separado pro bar', hyp: true, notHappened: true)],
    [L('ainda não paguei os 180 da luz', hyp: true, notHappened: true)],
    [L('cancelei a compra de 250 no pix', hyp: true, notHappened: true)],
    [L('por pouco não torrei 300 no cassino', hyp: true, notHappened: true)],
    [L('acabei de pagar 47 no sacolão no pix, se precisar te mando o comprovante', dir: 'expense', single: 47, exp: t, hyp: false)],
    [L('acabei de gastar 66 na papelaria no pix', dir: 'expense', single: 66, exp: t, hyp: false)],
    [L('a conta do bar ficou em 118 no pix, se quiser divido com vc', dir: 'expense', single: 118, exp: t, hyp: false)],
    [L('tive um gasto de 58 com remédio no pix, se for preciso guardo a nota', dir: 'expense', single: 58, exp: t, hyp: false)],
    [L('saíram 260 da conta pro mecânico, se eu achar a nota te mando', dir: 'expense', single: 260, exp: t, hyp: false)],
    [L('fui no dentista e saiu 175 no débito, se precisar volto lá', dir: 'expense', single: 175, exp: t, hyp: false)],
    [L('botei 120 de gasolina no débito, caso o tanque estivesse vazio', dir: 'expense', single: 120, exp: t, hyp: false)],
    [L('recebi 200 da carla no pix, se ela pagar o resto te aviso', dir: 'income', single: 200, exp: t, hyp: false)],
    [L('a pizza custou 85 no pix, se sobrar eu levo amanhã pro trabalho', dir: 'expense', single: 85, exp: t, hyp: false)],
    [L('comprei um vestido de 260 no pix caso tenha festa', dir: 'expense', single: 260, exp: t, hyp: false)],
    [L('o cliente me pagou 900 no pix, se quiser confere no extrato', dir: 'income', single: 900, exp: t, hyp: false)],
    [L('hoje rolou um gasto de 37 no petshop no pix, caso queira saber', dir: 'expense', single: 37, exp: t, hyp: false)],
    // hipótese com lote pendente (7a) e com rascunho
    [L('gastei 23 no chaveiro e 14 na banca'), L('e se fosse no débito?', hyp: true), L('no pix', values: [23, 14])],
    [L('gastei no sacolão no pix'), L('se for 47', hyp: true), L('no pix', hyp: true)],
    // ── C. contagem de valores ──
    [L('comprei um iphone 13 por 2500 no pix', dir: 'expense', single: 2500, exp: t, one: true)],
    [L('paguei 380 no pneu aro 14 no pix', dir: 'expense', single: 380, exp: t, one: true)],
    [L('comprei uma tv de 50 polegadas por 2300 no pix', dir: 'expense', single: 2300, exp: t, one: true)],
    [L('comprei 2 pão de queijo por 9 no pix', dir: 'expense', single: 9, exp: t, one: true)],
    [L('peguei 3 cerveja por 27 no pix', dir: 'expense', single: 27, exp: t, one: true)],
    [L('gastei 85 na loja 12 do shopping no pix', dir: 'expense', single: 85, exp: t, one: true)],
    [L('gastei 58 no mercado da rua 7 com a minha mãe no pix', dir: 'expense', single: 58, exp: t, one: true)],
    [L('paguei 23 no estacionamento das 14 às 18 no pix', dir: 'expense', single: 23, exp: t, one: true)],
    [L('paguei 9 de pedágio no km 32 no pix', dir: 'expense', single: 9, exp: t, one: true)],
    [L('comprei um tênis tamanho 42 por 260 no pix', dir: 'expense', single: 260, exp: t, one: true)],
    [L('paguei 118 na conta com 10% de serviço no pix', dir: 'expense', single: 118, exp: t, one: true)],
    [L('comprei 1 dúzia de ovos por 14 no pix', dir: 'expense', single: 14, exp: t, one: true)],
    [L('gastei 66 no presente do meu sobrinho de 5 anos no pix', dir: 'expense', single: 66, exp: t, one: true)],
    [L('paguei a 2ª parcela de 175 do sofá no pix', dir: 'expense', single: 175, exp: t, one: true)],
    [L('paguei o ipva 2026 de 1350 no pix', dir: 'expense', single: 1350, exp: t, one: true)],
    [L('comprei a camisa 10 do flamengo por 260 no pix', dir: 'expense', single: 260, exp: t, one: true)],
    [L('gastei 37 na farmácia do bloco 3 no pix', dir: 'expense', single: 37, exp: t, one: true)],
    [L('paguei 14 por 2 horas de estacionamento no pix', dir: 'expense', single: 14, exp: t, one: true)],
    [L('comprei 300g de presunto por 23 no pix', dir: 'expense', single: 23, exp: t, one: true)],
    [L('gastei 47,50 no sacolão no pix', dir: 'expense', single: 47.5, exp: t, one: true)],
    [L('gastei 1.250 no material de obra no pix', dir: 'expense', single: 1250, exp: t, one: true)],
    [L('gastei 23 no sacolão às 7 da manhã no pix', dir: 'expense', single: 23, exp: t, one: true)],
    [L('gastei 47 na papelaria, 3 cadernos e 2 canetas, no pix', dir: 'expense', single: 47, exp: t, one: true)],
    [L('paguei 470 na revisão dos 10 mil km no pix', dir: 'expense', single: 470, exp: t, one: true)],
    [L('paguei 40 no corte de cabelo, nota 10, no pix', dir: 'expense', single: 40, exp: t, one: true)],
    [L('gastei 85 com o kit 5 em 1 no pix', dir: 'expense', single: 85, exp: t, one: true)],
    [L('gastei 23 no açougue / 14 na padaria no pix', dir: 'expense', values: [23, 14])],
    [L('gastei 23 no açougue + 14 na padaria no pix', dir: 'expense', values: [23, 14])],
    [L('gastei 23 no açougue | 14 na padaria no pix', dir: 'expense', values: [23, 14])],
    [L('gastei 23 no açougue, daí 14 na padaria no pix', dir: 'expense', values: [23, 14])],
    [L('gastei 23 no açougue além de 14 na padaria no pix', dir: 'expense', values: [23, 14])],
    [L('gastei 23 no açougue fora os 14 da padaria no pix', dir: 'expense', values: [23, 14])],
    [L('gastei 23 no açougue sem contar os 14 da padaria no pix', dir: 'expense', values: [23, 14])],
    [L('açougue 23; padaria 14 no pix', dir: 'expense', values: [23, 14])],
    [L('açougue: 23, padaria: 14 no pix', dir: 'expense', values: [23, 14])],
    [L('23 açougue 14 padaria no pix', dir: 'expense', values: [23, 14])],
    [L('gastei 23 no açougue mais 14 na padaria no pix', dir: 'expense', values: [23, 14])],
    [L('gastei 23 no açougue aí 14 na padaria no pix', dir: 'expense', values: [23, 14])],
    [L('paguei 260 de entrada e 85 de frete no pix', dir: 'expense', values: [260, 85])],
    [L('gastei 23 no açougue\n14 na padaria no pix', dir: 'expense', values: [23, 14])],
    [L('paguei 85 de academia e 85 de inglês no pix', dir: 'expense', values: [85, 85])],
    [L('gastei 118 com o veterinário 66 com a ração no pix', dir: 'expense', values: [118, 66])],
    [L('torrei 23 no açougue e 14 na padaria e 23 no chaveiro no pix', dir: 'expense', values: [23, 14, 23])],
    [L('recebi 400 do bico e torrei 85 no bar no pix', values: [400, 85], valueDir: {400: 'income', 85: 'expense'})],
    [L('vendi o fogão por 300 e comprei um micro-ondas de 520 no pix', values: [300, 520], valueDir: {300: 'income', 520: 'expense'})],
    [L('paguei 175 de luz e o inquilino me pagou 1350 no pix', values: [175, 1350], valueDir: {175: 'expense', 1350: 'income'})],
    // ── D. datas ──
    [L('gastei 18 no Café Amanhã no pix', dir: 'expense', single: 18, exp: t, title: true)],
    [L('gastei 27 na Lanchonete Quinta Avenida no pix', dir: 'expense', single: 27, exp: t, title: true)],
    [L('gastei 41 no Hortifruti Terça Verde no pix', dir: 'expense', single: 41, exp: t, title: true)],
    [L('gastei 95 na Loja 25 de Março no pix', dir: 'expense', single: 95, exp: t, title: true)],
    [L('gastei 64 no Bar Dia 15 no pix', dir: 'expense', single: 64, exp: t, title: true)],
    [L('gastei 132 no Mercado Dia a Dia no pix', dir: 'expense', single: 132, exp: t, title: true)],
    [L('gastei 52 na Drogaria Domingo no pix', dir: 'expense', single: 52, exp: t, title: true)],
    [L('gastei 85 no Restaurante Sexta-Feira 13 no pix', dir: 'expense', single: 85, exp: t, title: true, one: true)],
    [L('gastei 150 na rua 25 de março no pix'), L('loja', dir: 'expense', single: 150, exp: t, title: true)],
    [L('gastei 90 numa loja da avenida 7 de setembro no pix'), L('roupa', dir: 'expense', single: 90, exp: t, title: true)],
    [L('gastei 60 na rua 13 de maio no pix'), L('mercado', dir: 'expense', single: 60, exp: t, title: true)],
    [L('comprei na 25 de março 150 no pix', dir: 'expense', single: 150, exp: t, title: true)],
    [L('paguei 85 na aula 5/8 do curso no pix', dir: 'expense', single: 85, exp: t, title: true, one: true)],
    [L('gastei 47 na sessão 4/6 do pilates no pix', dir: 'expense', single: 47, exp: t, title: true, one: true)],
    [L('paguei 30 na rodada 3/5 do bolão no pix', dir: 'expense', single: 30, exp: t, title: true, one: true)],
    [L('paguei 260 no plantão 12/12 do hospital no pix', dir: 'expense', single: 260, exp: t, title: true, one: true)],
    [L('comprei um tênis 40/41 por 260 no pix', dir: 'expense', single: 260, exp: t, title: true, one: true)],
    [L('gastei 23 na Sorveteria Sábado Feliz no pix', dir: 'expense', single: 23, exp: t, title: true)],
    [L('gastei 150 na rua 25 de março no pix', dir: 'expense', single: 150, exp: t, title: true)],
    [L('gastei 90 numa loja da avenida 7 de setembro no pix', dir: 'expense', single: 90, exp: t, title: true)],
    [L('paguei 30 no estacionamento da praça 15 de novembro no pix', dir: 'expense', single: 30, exp: t, title: true)],
    [L('gastei 60 na rua 13 de maio no pix', dir: 'expense', single: 60, exp: t, title: true)],
    [L('gastei 14 na padaria pão de hoje no pix', dir: 'expense', single: 14, exp: t, title: true)],
    [L('comprei um tênis 38/39 por 200 no pix', dir: 'expense', single: 200, exp: t, title: true, one: true)],
    [L('comprei um pneu 175/70 por 380 no pix', dir: 'expense', single: 380, exp: t, title: true, one: true)],
    [L('paguei 60 no ingresso do setor 2/3 no pix', dir: 'expense', single: 60, exp: t, title: true, one: true)],
    [L('o jogo terminou 3/1 e gastei 85 no bar no pix', dir: 'expense', single: 85, exp: t, title: true, one: true)],
    [L('comprei 3/4 de queijo por 37 no pix', dir: 'expense', single: 37, exp: t, title: true, one: true)],
    [L('gastei 47 no sacolão em 15/11 no pix', dir: 'expense', single: 47, ask: true)],
    [L('gastei 47 no sacolão no dia 15/11 no pix', dir: 'expense', single: 47, ask: true)],
    [L('gastei 47 no sacolão em 31/09 no pix', dir: 'expense', single: 47, ask: true)],
    [L('gastei 47 no sacolão em 14/09 no pix', dir: 'expense', single: 47, exp: DateTime(t.year, 9, 14))],
    [L('gastei 47 no sacolão em 2 de agosto no pix', dir: 'expense', single: 47, exp: DateTime(t.year, 8, 2))],
    [L('gastei 47 no sacolão em 2 de dezembro no pix', dir: 'expense', single: 47, ask: true)],
    [L('gastei 47 no sacolão dia 29 do mês passado no pix', dir: 'expense', single: 47, exp: DateTime(t.year, t.month - 1, 29))],
    [L('gastei 47 no sacolão dia 31 do mês passado no pix', dir: 'expense', single: 47, exp: _daysIn(t.year, t.month - 1) >= 31 ? DateTime(t.year, t.month - 1, 31) : null, ask: _daysIn(t.year, t.month - 1) < 31)],
    [L('tem cinco dias que gastei 47 no sacolão no pix', dir: 'expense', single: 47, exp: back(5))],
    [L('gastei 47 no sacolão faz dez dias no pix', dir: 'expense', single: 47, exp: back(10))],
    [L('gastei 47 no sacolão quarta no pix', dir: 'expense', single: 47, exp: wdLast(3), expAlt: {t})],
    [L('gastei 47 no sacolão terça retrasada no pix', dir: 'expense', single: 47, exp: DateTime(wdLast(2).year, wdLast(2).month, wdLast(2).day - 7))],
    [L('gastei 47 no sacolão no começo do mês no pix', dir: 'expense', single: 47, vague: true)],
    [L('gastei 47 no sacolão esses dias no pix', dir: 'expense', single: 47, vague: true)],
    [L('gastei 47 no sacolão semana passada no pix', dir: 'expense', single: 47, vague: true)],
    [L('gastei 47 no sacolão daqui a 3 dias no pix', dir: 'expense', single: 47, ask: true)],
    [L('gastei 47 no sacolão na próxima segunda no pix', dir: 'expense', single: 47, ask: true)],
    // data da resposta no merge
    [L('gastei no sacolão no pix'), L('deu 47 ontem à noite', dir: 'expense', single: 47, exp: back(1), answer: true)],
    [L('gastei no sacolão no pix'), L('foi 47 há dois dias', dir: 'expense', single: 47, exp: back(2), answer: true)],
    [L('gastei no sacolão no pix'), L('foi 47 no domingo', dir: 'expense', single: 47, exp: wdLast(7), answer: true)],
    [L('gastei no sacolão no pix'), L('47 dia 1º', dir: 'expense', single: 47, exp: diaN(1), answer: true)],
    [L('gastei no sacolão no pix'), L('47 dia 15/11', dir: 'expense', single: 47, ask: true, answer: true)],
    [L('gastei no sacolão no pix'), L('47, mas foi anteontem', dir: 'expense', single: 47, exp: back(2), answer: true)],
    [L('gastei no sacolão no pix'), L('foi ontem, 47', dir: 'expense', single: 47, exp: back(1), answer: true)],
    [L('gastei no sacolão ontem no pix'), L('47', dir: 'expense', single: 47, exp: back(1), answer: true)],
    [L('gastei no sacolão no pix'), L('ontem'), L('47', dir: 'expense', single: 47, exp: back(1), answer: true)],
    // data compartilhada / por item no multi
    [L('anteontem: 23 no chaveiro e 14 na banca no pix', dir: 'expense', values: [23, 14], exp: back(2))],
    [L('gastei 23 no chaveiro e 14 na banca, tudo ontem, no pix', dir: 'expense', values: [23, 14], exp: back(1))],
    [L('no domingo gastei 23 no petshop, 14 na lotérica e 9 na banca no pix', dir: 'expense', values: [23, 14, 9], exp: wdLast(7))],
    [L('gastei 23 no chaveiro e 14 na banca há três dias no pix', dir: 'expense', values: [23, 14], exp: back(3))],
    [L('ontem gastei 23 no chaveiro e hoje 14 na banca no pix', dir: 'expense', values: [23, 14], valueDate: {23: back(1), 14: t})],
    [L('gastei 23 no chaveiro na segunda e 14 na banca na terça no pix', dir: 'expense', values: [23, 14], valueDate: {23: wdLast(1), 14: wdLast(2)})],
    [L('gastei 23 no chaveiro e 14 na banca em 15/11 no pix', dir: 'expense', values: [23, 14], ask: true)],
    // ── E. rascunho pendente ──
    [L('paguei o chaveiro no pix'), L('deu 47 certinho', dir: 'expense', single: 47, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('paguei 47', dir: 'expense', single: 47, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('quarenta e sete', dir: 'expense', single: 47, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('cento e vinte', dir: 'expense', single: 120, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('47,90', dir: 'expense', single: 47.9, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('R\$47', dir: 'expense', single: 47, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('47 pila', dir: 'expense', single: 47, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('99', dir: 'expense', single: 99, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('47, não, 52', dir: 'expense', single: 52, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('foi 47 quer dizer 52', dir: 'expense', single: 52, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('47… aliás 52', dir: 'expense', single: 52, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('47 ou 52', values: [47, 52])],
    [L('paguei o chaveiro no pix'), L('uns 47 a 52', values: [47, 52])],
    [L('paguei o chaveiro no pix'), L('47 mais 10 de gorjeta', values: [47, 10])],
    [L('paguei o chaveiro no pix'), L('47 pra mim e 52 pro joão', values: [47, 52])],
    [L('paguei o chaveiro no pix'), L('47 e pouco', dir: 'expense', single: 47, exp: t, answer: true)],
    [L('paguei o chaveiro no pix'), L('gastei 14 na banca no pix', dir: 'expense', single: 14, exp: t, newWord: 'banca', oldWord: 'chaveiro')],
    [L('paguei o chaveiro no pix'), L('tomei um café de 9 no pix', dir: 'expense', single: 9, exp: t, newWord: 'cafe', oldWord: 'chaveiro')],
    [L('paguei o chaveiro no pix'), L('comprei um carregador de 58 no pix', dir: 'expense', single: 58, exp: t, newWord: 'carregador', oldWord: 'chaveiro')],
    [L('gastei com o veterinário no pix'), L('recebi 640 de comissão no pix', dir: 'income', single: 640, exp: t, newWord: 'comissao', oldWord: 'veterinario')],
    [L('gastei com o veterinário no pix'), L('vendi a cadeira por 85 no pix', dir: 'income', single: 85, exp: t, newWord: 'cadeira', oldWord: 'veterinario')],
    [L('o inquilino me pagou no pix'), L('o síndico me cobrou 130 de multa no pix', dir: 'expense', single: 130, exp: t, newWord: 'multa', oldWord: 'inquilino')],
    [L('o inquilino me pagou no pix'), L('paguei 23 de estacionamento no pix', dir: 'expense', single: 23, exp: t, newWord: 'estacionamento', oldWord: 'inquilino')],
    [L('paguei o chaveiro no pix'), L('paguei a academia'), L('85', single: 85, exp: t, answer: true)],
    [L('o inquilino me pagou no pix'), L('comprei pão'), L('9', single: 9, exp: t, answer: true)],
    [L('gastei no Café Amanhã no pix'), L('18', dir: 'expense', single: 18, exp: t, title: true, answer: true)],
    [L('paguei a lanchonete quinta avenida no pix'), L('27', dir: 'expense', single: 27, exp: t, title: true, answer: true)],
    // ── F. resolvedor (fixtures novas) ──
    [L('muda o café amanhã pra 20', named: 'cafe', edit: 20)],
    [L('apaga o café amanhã', named: 'cafe'), L('sim', named: 'cafe')],
    [L('muda a lanchonete quinta avenida pra 30', named: 'lanchonete', edit: 30), L('sim', named: 'lanchonete', edit: 30)],
    [L('muda o hortifruti terça verde pra 45', named: 'hortifruti', edit: 45), L('sim', named: 'hortifruti', edit: 45)],
    [L('apaga o hortifruti de domingo', named: 'hortifruti'), L('sim', named: 'hortifruti')],
    [L('muda a loja 25 de março pra 99', named: 'loja', edit: 99), L('sim', named: 'loja', edit: 99)],
    [L('muda o bar dia 15 pra 70', named: 'bar', edit: 70), L('sim', named: 'bar', edit: 70)],
    [L('muda o mercado dia a dia pra 140', named: 'mercado', edit: 140)],
    [L('apaga a drogaria domingo', named: 'drogaria'), L('sim', named: 'drogaria'), L('sim', named: 'drogaria')],
    [L('muda a feira de ontem pra 70', named: 'feira', edit: 70), L('sim', named: 'feira', edit: 70)],
    [L('muda o uber de segunda pra 40', named: 'uber', edit: 40), L('sim', named: 'uber', edit: 40)],
    [L('muda a gasolina de segunda pra 200', named: 'gasolina', edit: 200), L('sim', named: 'gasolina', edit: 200)],
    [L('muda a comida de segunda pra 30', named: 'comida', edit: 30), L('sim', named: 'comida', edit: 30)],
    [L('passa o posto shell pra 190', named: 'posto', edit: 190)],
    [L('passa o açougue de sexta pra 80', named: 'acougue', edit: 80)],
    [L('passa o 99 pra 25', named: '99', edit: 25)],
    [L('passa o bico pra 450', named: 'bico', edit: 450)],
    [L('passa 50 pro joão', named: 'joao')],
    [L('o sacolão foi 40', named: 'sacolao', edit: 40)],
    [L('na verdade o açougue foi 80', named: 'acougue', edit: 80)],
    [L('corrige o aluguel pra 1450', named: 'aluguel', edit: 1450)],
    [L('apaga o mercado de domingo', named: 'mercado'), L('sim', named: 'mercado'), L('sim', named: 'mercado')],
    [L('exclui o lanche de segunda', named: 'lanche'), L('sim', named: 'lanche')],
    [L('muda o café de ontem pra 20', named: 'cafe', edit: 20)],
    [L('apaga o bar dia 15', named: 'bar'), L('esse', named: 'bar'), L('sim', named: 'bar')],
    [L('muda a sorveteria de sábado pra 30', named: 'sorveteria', edit: 30), L('sim', named: 'sorveteria', edit: 30)],
    [L('apaga a loja do dia 25', named: 'loja'), L('pode ser', named: 'loja'), L('sim', named: 'loja')],
    [L('muda o posto de anteontem pra 190', named: 'posto', edit: 190)],
    [L('muda o remédio de quinta pra 60', named: 'remedio', edit: 60)],
    [L('passa a drogaria pra 60', named: 'drogaria', edit: 60)],
    [L('passa o mercado dia a dia pra dinheiro', named: 'mercado')],
    // achados da triagem (reproduzíveis em 1–3 turnos)
    [L('hoje lembrei que gastei 50 no mercado ontem no pix', dir: 'expense', single: 50, exp: back(1))],
    [L('só hoje vi que paguei 80 de luz anteontem no pix', dir: 'expense', single: 80, exp: back(2))],
    [L('ontem gastei 50 no mercado, hoje tô sem grana, no pix', dir: 'expense', single: 50, exp: back(1))],
    [L('dia 12/09 a cliente me transferiu 85 na Loja 25 de Março no dinheiro', dir: 'income', single: 85, exp: DateTime(t.year, 9, 12))],
    [L('vendemos o fogão velho por 85 na terça-feira passada na rua 13 de maio no pix', dir: 'income', single: 85, exp: wdLast(2))],
    [L('fechei uma venda de 85 na sexta-feira passada na padaria pão de hoje no débito', dir: 'income', single: 85, exp: wdLast(5))],
    [L('há três dias cobrei a consulta de 47 do paciente no débito', dir: 'income', single: 47, exp: back(3))],
    [L('faz dois dias paguei a diária de 80 do hotel no pix', dir: 'expense', single: 80, alt: {160}, exp: back(2))],
    [L('faz seis dias veio a conta de água de 85 no crédito à vista', dir: 'expense', single: 85, exp: back(6))],
    [L('me pagaram 140 pela diária de pedreiro no pix', dir: 'income', obvious: true, single: 140, exp: t)],
    [L('fiz uma venda de 58 na banca no débito', dir: 'income', obvious: true, single: 58, exp: t)],
    [L('fechei uma venda de 58 no débito', dir: 'income', obvious: true), L('na banca', dir: 'income', single: 58, exp: t)],
    [L('herdei 5000 da minha avó na banca no débito', dir: 'income', single: 5000, exp: t)],
    [L('dia 9 tirei 85 vendendo trufa no dinheiro', dir: 'income', single: 85, exp: diaN(9))],
    [L('recebi 260 do joão e 9 da carla no pix', dir: 'income', values: [260, 9])],
    [L('açougue 23; padaria 14 no dinheiro, tudo no dia 21', dir: 'expense', values: [23, 14], exp: diaN(21))],
    [L('gastei 23 no açougue + 14 na padaria no pix, tudo anteontem', dir: 'expense', values: [23, 14], exp: back(2))],
    [L('tô planejando gastar 85 na viagem no pix', hyp: true)],
    [L('gastei 50 no mercado no pix'), L('passa'), L('gastei 30 na padaria no pix', dir: 'expense', single: 30, exp: t, newWord: 'padaria', oldWord: 'mercado')],
    [L('gastei 50 no mercado no pix'), L('muda'), L('recebi 300 de freela no pix', dir: 'income', single: 300, exp: t)],
    [L('cobrei a consulta de 175 do paciente no crédito à vista'), L('passa'), L('por pouco não torrei 118 no cassino', hyp: true, notHappened: true)],
    [L('gastei 66 na banca no pix'), L('na verdade o açougue foi 14', named: 'acougue', edit: 14)],
    [L('deu 66 ontem à noite'), L('todo dia 16 cai 58 da pensão'), L('gastei com o veterinário no pix')],
    [L('a mensalidade do curso de 58 vence dia 10'), L('paguei a manicure no débito')],
    [L('o inquilino me pagou no pix'), L('vendi a cadeira por 14 no pix', dir: 'income', single: 14, exp: t, newWord: 'cadeira', oldWord: 'inquilino')],
    [L('recebi o acerto do bico no pix'), L('foi 47 na segunda-feira', dir: 'income', single: 47, exp: wdLast(1), answer: true)],
    [L('saíram 260 da conta pro mecânico, se eu achar a nota te mando', dir: 'expense', single: 260, exp: t, hyp: false)],
    // pergunta pendente que sobrevive a outro comando (r3 pendencia_presa, nova depois da 7b)
    [L('gastei 60 no posto no débito'), L('cancela'), L('exclui o posto anteontem', named: 'posto'), L('sim', named: 'posto')],
    [L('gastei 60 no posto no débito'), L('cancela'), L('apaga o açougue de domingo', named: 'acougue'), L('sim', named: 'acougue')],
    [L('apaga o sacolão', named: 'sacolao'), L('muda o 99 de ontem pra 30', named: '99', edit: 30), L('sim', named: '99', edit: 30)],
    // palavra de categoria × título de OUTRO tipo (a 7b só separa combustível)
    [L('muda o cinema de segunda pra 30', named: 'cinema', edit: 30)],
    [L('o cinema de segunda foi 30', named: 'cinema', edit: 30)],
    [L('apaga o cinema de segunda', named: 'cinema'), L('sim', named: 'cinema')],
    [L('muda a padaria de ontem pra 20', named: 'padaria', edit: 20)],
    [L('muda o açougue de ontem pra 50', named: 'acougue', edit: 50)],
    [L('muda o uber de domingo pra 40', named: 'uber', edit: 40)],
    [L('muda o táxi de domingo pra 40', named: 'taxi', edit: 40)],
    [L('muda o pedágio de domingo pra 12', named: 'pedagio', edit: 12)],
    [L('muda o restaurante de segunda pra 30', named: 'restaurante', edit: 30)],
    [L('muda a pizza de ontem pra 30', named: 'pizza', edit: 30)],
    [L('muda o hortifruti de ontem pra 50', named: 'hortifruti', edit: 50)],
    [L('gastei 27 na lanchonete quinta avenida no pix', dir: 'expense', single: 27, exp: t, title: true)],
    [L('gastei 95 na Loja 25 de Março no pix'), L('compras', dir: 'expense', single: 95, exp: t, title: true)],
    [L('comprei na 25 de março 150 no pix'), L('roupa', dir: 'expense', single: 150, exp: t, title: true)],
    [L('passa o 99 pra 25', named: '99', edit: 25), L('pix', named: '99', edit: 25)],
    [L('muda o mercado de domingo pra 50', named: 'mercado', edit: 50), L('apaga o café amanhã', named: 'cafe'), L('sim', named: 'cafe')],
  ];
}

// ───────────────────────── relógio injetado ─────────────────────────

class ClockCase {
  final String phrase;
  final DateTime? exp;
  final bool invalid;
  final bool future;
  final Set<DateTime> alt;
  ClockCase(this.phrase, this.exp, {this.invalid = false, this.future = false, this.alt = const {}});
}

List<ClockCase> clockOracle(DateTime now) {
  final t = _day(now);
  final out = <ClockCase>[
    ClockCase('ontem a noite', back(1, t)),
    ClockCase('antes de ontem', back(2, t)),
    ClockCase('ha dois dias', back(2, t)),
    ClockCase('faz quinze dias', back(15, t)),
    ClockCase('tem tres dias que', back(3, t)),
    ClockCase('uns cinco dias atras', back(5, t)),
    ClockCase('ha 366 dias', back(366, t)),
    ClockCase('ha 367 dias', null, invalid: true),
    ClockCase('daqui a 2 dias', DateTime(t.year, t.month, t.day + 2), future: true),
    ClockCase('sabado retrasado', DateTime(wdLast(6, t).year, wdLast(6, t).month, wdLast(6, t).day - 7)),
    ClockCase('quarta retrasada', DateTime(wdLast(3, t).year, wdLast(3, t).month, wdLast(3, t).day - 7)),
    ClockCase('dia 1º', diaN(1, t)),
  ];
  for (final wd in _wdNames.entries) {
    final name = CategoryNameMatcher.foldAccents(wd.value);
    final same = wd.key == t.weekday;
    out.add(ClockCase(wd.key <= 5 ? '$name-feira' : name, wdLast(wd.key, t), alt: same ? {t} : const {}));
    out.add(ClockCase('proxim${wd.key >= 6 ? 'o' : 'a'} $name', null, future: true));
  }
  for (final n in [1, 15, 28, 29, 30, 31]) {
    final first = DateTime(t.year, t.month - 1, 1);
    final ok = n <= _daysIn(first.year, first.month);
    out.add(ClockCase('dia $n do mes passado', ok ? DateTime(first.year, first.month, n) : null, invalid: !ok));
  }
  for (final p in [
    [31, 12], [1, 1], [29, 2], [28, 2], [1, 3], [30, 11], [15, 11], [2, 10], [30, 9], [31, 10], [24, 12], [0, 3], [12, 0],
  ]) {
    final o = ddmmOracle(p[0], p[1], t);
    final txt = 'em ${p[0].toString().padLeft(2, '0')}/${p[1].toString().padLeft(2, '0')}';
    out.add(ClockCase(txt, o.date, invalid: o.date == null, future: o.ask));
  }
  for (final p in [
    [31, 12], [29, 2], [1, 1], [7, 9],
  ]) {
    final o = ddmmOracle(p[0], p[1], t);
    out.add(ClockCase('${p[0]} de ${CategoryNameMatcher.foldAccents(_monthNames[p[1] - 1])}', o.date, invalid: o.date == null, future: o.ask));
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  test('CHAOS-B casos-alvo', () async {
    var n = 0, bad = 0;
    final byKind = <String, int>{};
    for (final seq in targeted()) {
      n += seq.length;
      final res = await runB(engine, fixed: seq);
      final repo = await freshRepo();
      final sim = SimB(engine, repo);
      final replies = <String>[];
      final beforeIds = repo.transactions.map((e) => e.id).toSet();
      for (final lt in seq) {
        replies.add(sim.send(lt.text).short);
      }
      final added = repo.transactions
          .where((x) => !beforeIds.contains(x.id))
          .map((x) => '${x.title} ${x.amount} ${x.type.name} ${ddmmyy(x.date)}${x.isRecurrent ? ' REC' : ''}')
          .toList();
      final label = seq.map((e) => '"${e.text.replaceAll('\n', r'\n')}"').join(' ⏎ ');
      print('CHAOS-B|ALVO| $label ⇒ ${replies.join(' ⏎ ')} ⇒ novos=$added');
      for (final x in res.v) {
        bad++;
        byKind[x.kind] = (byKind[x.kind] ?? 0) + 1;
        print('CHAOS-B|ALVO-V| ${x.kind}: $label :: ${x.detail}');
      }
    }
    print('CHAOS-B|RESUMO| alvo: ${targeted().length} sequências, $n turnos, $bad violações: $byKind');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('CHAOS-B relógio injetado no SpokenDayParser', () {
    final clocks = [
      DateTime(2026, 11, 1, 10), DateTime(2028, 2, 29, 12), DateTime(2028, 3, 1, 8), DateTime(2026, 12, 31, 23, 59, 59), DateTime(2027, 1, 1, 0, 0, 1),
      DateTime(2026, 10, 4, 12), DateTime(2026, 10, 5, 0, 0, 1), DateTime(2027, 2, 28, 12), DateTime(2027, 3, 1, 9), DateTime(2026, 9, 30, 12),
      DateTime(2027, 3, 31, 12), DateTime(2026, 10, 31, 23, 0),
    ];
    var n = 0, bad = 0;
    for (final now in clocks) {
      for (final c in clockOracle(now)) {
        n++;
        final phrase = 'paguei 47 no chaveiro ${c.phrase} no pix';
        final res = SpokenDayParser.parse(SpokenDayParser.normalizeWeekdays(CategoryNameMatcher.foldAccents(phrase)), now: now, allowFuture: true);
        final got = res?.day;
        var problem = '';
        if (c.invalid && !c.future) {
          if (res == null || res.invalid == null) problem = 'data inexistente aceita: ${got == null ? 'null' : ddmmyy(got.start)}';
        } else if (c.future) {
          // Futuro: o motor só pode gravar com offset <= 0; tem de ser lido como futuro (pergunta) ou inválido.
          if (got != null && got.offsetFrom(now) <= 0) problem = 'futuro lido como passado ${ddmmyy(got.start)}';
          if (got == null && (res == null || res.invalid == null)) problem = 'futuro não lido (gravaria hoje)';
        } else if (got == null) {
          problem = 'não leu a data (${res?.invalid})';
        } else if (!got.isRange && _day(got.start) != c.exp && !c.alt.contains(_day(got.start))) {
          problem = 'leu ${ddmmyy(got.start)}, esperado ${ddmmyy(c.exp!)}';
        } else if (got.offsetFrom(now) > 0) {
          problem = 'data futura ${ddmmyy(got.start)}';
        }
        if (problem.isNotEmpty) {
          bad++;
          print('CHAOS-B|RELOGIO-V| hoje=${ddmmyy(now)} ${now.hour}:${now.minute}:${now.second} "$phrase" → $problem');
        }
      }
      for (final title in [
        'no Cafe Amanha', 'na Loja 25 de Marco', 'na rua 25 de marco', 'no Mercado Dia a Dia', 'no Bar Dia 15', 'na Lanchonete Quinta Avenida',
        'no tenis 38/39', 'no pneu 175/70', 'no setor 2/3', 'em 3/4 de queijo',
      ]) {
        n++;
        final r = SpokenDayParser.parse(SpokenDayParser.normalizeWeekdays(CategoryNameMatcher.foldAccents('gastei 50 $title no pix'.toLowerCase())), now: now, allowFuture: true);
        if (r != null) {
          stat('titulo_lido_como_data_parser');
          print('CHAOS-B|RELOGIO-T| hoje=${ddmmyy(now)} "gastei 50 $title no pix" → ${r.day == null ? 'inválida: ${r.invalid}' : ddmmyy(r.day!.start)} (matched "${r.day?.matched ?? r.matched}")');
        }
      }
    }
    print('CHAOS-B|RESUMO| relógio: ${clocks.length} relógios, $n leituras, $bad divergências do oráculo');
  });

  test('CHAOS-B relógio injetado na referência (editar/apagar)', () async {
    final clocks = <String, DateTime>{
      '1º do mês (dom)': DateTime(2026, 11, 1, 10),
      '29/02 (ter)': DateTime(2028, 2, 29, 12),
      '01/03 bissexto (qua)': DateTime(2028, 3, 1, 8),
      '31/12 23:59': DateTime(2026, 12, 31, 23, 59, 59),
      '01/01 00:00:01 (sex)': DateTime(2027, 1, 1, 0, 0, 1),
      'domingo': DateTime(2026, 10, 4, 12),
      'segunda 00:00:01': DateTime(2026, 10, 5, 0, 0, 1),
      '01/03 (seg)': DateTime(2027, 3, 1, 9),
    };
    var n = 0, bad = 0;
    for (final ck in clocks.entries) {
      final now = ck.value;
      final t = _day(now);
      DateTime at(DateTime d) => DateTime(d.year, d.month, d.day, 0, 30);
      final ontem = back(1, t);
      final fx = <FinancialTransaction>[
        FinancialTransaction(id: 'ck-feira-dom', title: 'Feira', amount: 61, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: at(wdLast(7, now))),
        FinancialTransaction(id: 'ck-feira-qua', title: 'Feira', amount: 62, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: at(wdLast(3, now))),
        FinancialTransaction(id: 'ck-cafe-amanha', title: 'Café Amanhã', amount: 63, type: TransactionType.expense, category: 'leisure', paymentMethod: 'pix', date: at(ontem)),
        FinancialTransaction(id: 'ck-mercado-dad', title: 'Mercado Dia a Dia', amount: 64, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: at(back(2, t))),
        FinancialTransaction(id: 'ck-bar-dia15', title: 'Bar Dia 15', amount: 65, type: TransactionType.expense, category: 'leisure', paymentMethod: 'pix', date: at(ontem)),
        FinancialTransaction(id: 'ck-99-ontem', title: '99', amount: 66, type: TransactionType.expense, category: 'transport', paymentMethod: 'pix', date: at(ontem)),
        FinancialTransaction(id: 'ck-horti-tv', title: 'Hortifruti Terça Verde', amount: 67, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: at(wdLast(5, now))),
        FinancialTransaction(id: 'ck-sacolao-dia1', title: 'Sacolão', amount: 68, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: at(diaN(1, now)!)),
        FinancialTransaction(id: 'ck-loja-25', title: 'Loja 25 de Março', amount: 69, type: TransactionType.expense, category: 'expense_other', paymentMethod: 'pix', date: at(back(3, t))),
      ];
      bool sameDay(FinancialTransaction x, DateTime? d) => d != null && _day(x.date) == _day(d);
      final cases = <List<Object>>[
        [['muda a feira de domingo pra 91'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, wdLast(7, now))],
        [['apaga a feira de quarta', 'sim'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, wdLast(3, now))],
        [['muda o café amanhã pra 92', 'sim'], (FinancialTransaction x) => x.title.startsWith('Café')],
        [['apaga o café amanhã', 'sim', 'sim'], (FinancialTransaction x) => x.title.startsWith('Café')],
        [['muda o mercado dia a dia pra 93', 'sim'], (FinancialTransaction x) => x.title.startsWith('Mercado')],
        [['muda o bar dia 15 pra 94', 'sim'], (FinancialTransaction x) => x.title.startsWith('Bar')],
        [['muda a gasolina de ontem pra 95', 'sim'], (FinancialTransaction x) => false],
        [['muda o uber de ontem pra 96', 'sim'], (FinancialTransaction x) => false],
        [['passa o 99 pra 97'], (FinancialTransaction x) => x.title == '99'],
        [['muda o hortifruti terça verde pra 98', 'sim'], (FinancialTransaction x) => x.title.startsWith('Hortifruti')],
        [['muda o sacolão do dia 1º pra 99'], (FinancialTransaction x) => x.title == 'Sacolão'],
        [['muda o sacolão do dia 1 pra 100'], (FinancialTransaction x) => x.title == 'Sacolão'],
        [['apaga o sacolão do dia 1', 'sim'], (FinancialTransaction x) => x.title == 'Sacolão'],
        [['muda a loja 25 de março pra 101', 'sim'], (FinancialTransaction x) => x.title.startsWith('Loja')],
        [['muda a feira de 29/02 pra 102'], (FinancialTransaction x) => x.title == 'Feira' && x.date.day == 29 && x.date.month == 2],
        [['muda a feira de 31/12 pra 103'], (FinancialTransaction x) => x.title == 'Feira' && x.date.day == 31 && x.date.month == 12],
        [['muda a feira do dia 30 pra 104'], (FinancialTransaction x) => x.title == 'Feira' && x.date.day == 30],
        [['muda a feira de anteontem pra 105'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, back(2, t))],
        [['apaga a feira do domingo passado', 'sim'], (FinancialTransaction x) => x.title == 'Feira' && sameDay(x, wdLast(7, now))],
        [['muda a comida de ontem pra 106', 'sim'], (FinancialTransaction x) => false],
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
        final sim = SimB(engine, repo, now: () => now);
        var prevText = '';
        var prevRoute = '';
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
            if (removed.contains(k) && !(prevRoute == 'confirm_delete' && yesRe.hasMatch(CesarText.simplify(turn)))) {
              bad++;
              print('CHAOS-B|REFCLOCK-V| apagou_sem_sim hoje=${ck.key}: $label → [${r.route}] ${x.title}');
            }
            if (allowed(x)) continue;
            final shown = prevText.contains(x.title);
            bad++;
            print('CHAOS-B|REFCLOCK-V| ${shown ? 'confirmou_outro' : 'atingiu_outro'} hoje=${ck.key} ${ddmmyy(now)}: $label → [${r.route}] '
                '${removed.contains(k) ? 'apagou' : 'mudou'} ${x.title} ${CesarText.money(x.amount)} de ${ddmmyy(x.date)} :: ${r.text.replaceAll('\n', ' ')}');
          }
          for (final k in changed) {
            final d = _day(DateTime.parse((jsonDecode(afterSnap.tx[k]!) as Map)['date'] as String));
            if (d.isAfter(t)) {
              bad++;
              print('CHAOS-B|REFCLOCK-V| data_futura hoje=${ck.key}: $label → ${describeTx(afterSnap.tx[k]!)}');
            }
          }
          prevText = r.text;
          prevRoute = r.route;
          print('CHAOS-B|REFCLOCK| hoje=${ck.key} ${ddmmyy(now)} "$turn" → ${r.short}');
        }
      }
    }
    print('CHAOS-B|RESUMO| referência×relógio: ${clocks.length} relógios, $n turnos, $bad violações');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('CHAOS-B palavra de categoria sem nenhum título com a palavra', () async {
    // O resolvedor só usa a categoria quando NENHUM título tem a palavra; a 7b
    // separa só combustível ("namesOtherKind"). Sem nenhum "Uber" salvo, "o
    // uber de domingo" não pode virar o Estacionamento de domingo.
    final cmds = <List<Object>>[
      [['muda o uber de domingo pra 40'], 'uber'],
      [['o uber de domingo foi 40'], 'uber'],
      [['apaga o uber de domingo', 'sim'], 'uber'],
      [['muda o remédio de domingo pra 40'], 'remedio'],
      [['muda a farmácia de domingo pra 40'], 'farmacia'],
      [['muda a feira de domingo pra 40'], 'feira'],
      [['muda o restaurante de ontem pra 40'], 'restaurante'],
      [['muda o curso de domingo pra 40'], 'curso'],
      [['muda a conta de casa de domingo pra 40'], 'conta'],
    ];
    var bad = 0;
    for (final c in cmds) {
      final repo = await freshRepo();
      for (final x in [...repo.transactions]) {
        if (RegExp(r'uber|feira|farm|restaur|curso|remed', caseSensitive: false).hasMatch(x.title)) repo.deleteTransaction(x.id);
      }
      repo.addTransaction(FinancialTransaction(
          id: 'cx-curso', title: 'Livraria', amount: 33, type: TransactionType.expense, category: 'education', paymentMethod: 'pix', date: wdLast(7).add(const Duration(hours: 9))));
      repo.addTransaction(FinancialTransaction(
          id: 'cx-casa', title: 'Material de construção', amount: 44, type: TransactionType.expense, category: 'housing', paymentMethod: 'pix', date: wdLast(7).add(const Duration(hours: 9))));
      final sim = SimB(engine, repo);
      final turns = c[0] as List<String>;
      final word = c[1] as String;
      var prevText = '';
      var prevRoute = '';
      for (final turn in turns) {
        final before = Snap3.of(repo);
        final r = sim.send(turn);
        final after = Snap3.of(repo);
        final touched = [
          ...before.tx.keys.where((k) => !after.tx.containsKey(k)),
          ...before.tx.keys.where((k) => after.tx.containsKey(k) && after.tx[k] != before.tx[k]),
        ];
        for (final k in touched) {
          final title = (jsonDecode(before.tx[k]!) as Map)['title'] as String;
          if (CesarText.fold(title).contains(word)) continue;
          bad++;
          final shown = prevText.contains(title) && (prevRoute == 'confirm_delete' || prevRoute == 'choose' || prevRoute == 'confirm');
          print('CHAOS-B|CAT-V| ${shown ? 'confirmou_outro' : 'atingiu_outro'}: ${turns.map((e) => '"$e"').join(' ⏎ ')} → [${r.route}] '
              '${describeTx(before.tx[k]!)} ⇒ ${after.tx[k] == null ? 'APAGADO' : describeTx(after.tx[k]!)} :: ${r.text.replaceAll(RegExp(r'\s+'), ' ')}');
        }
        print('CHAOS-B|CAT| "$turn" → ${r.short}');
        prevText = r.text;
        prevRoute = r.route;
      }
    }
    print('CHAOS-B|RESUMO| categoria sem título: ${cmds.length} comandos, $bad violações');
  });

  test('CHAOS-B fuzz (seeds novas 20261200+n)', () async {
    final sw = Stopwatch()..start();
    final seeds = int.tryParse(Platform.environment['B_SEEDS'] ?? '') ?? 24;
    final length = int.tryParse(Platform.environment['B_LEN'] ?? '') ?? 250;
    var turns = 0;
    final firstBy = <String, List<LT>>{};
    final firstSeed = <String, int>{};
    final countBy = <String, int>{};
    final distinct = <String, Set<String>>{};
    for (var n = 1; n <= seeds; n++) {
      final seed = 20261200 + n;
      final res = await runB(engine, gen: GenB(Random(seed), length));
      turns += res.sent.length;
      for (final x in res.v) {
        if (Platform.environment['B_ALLV'] == '1') print('CHAOS-B|FUZZ-V| ${x.kind} seed=$seed turno ${x.turn + 1}: ${x.detail}');
        countBy[x.kind] = (countBy[x.kind] ?? 0) + 1;
        (distinct[x.kind] ??= {}).add(res.sent[x.turn].text.replaceAll(RegExp(r'\d+'), '#').replaceAll('\n', r'\n'));
        if (!firstBy.containsKey(x.kind)) {
          firstBy[x.kind] = res.sent;
          firstSeed[x.kind] = seed;
          print('CHAOS-B|FUZZ| primeira ${x.kind} seed=$seed turno ${x.turn + 1}: ${x.detail}');
        }
      }
      print('CHAOS-B|FUZZ| seed=$seed turnos=${res.sent.length} violações=${res.v.length} (${sw.elapsedMilliseconds} ms)');
    }
    print('CHAOS-B|RESUMO| fuzz: $seeds seeds × $length = $turns turnos; ${sw.elapsedMilliseconds} ms');
    print('CHAOS-B|RESUMO| violações por tipo: $countBy');
    for (final e in distinct.entries) {
      print('CHAOS-B|FUZZ-FORMAS| ${e.key} (${e.value.length} formas): ${e.value.take(30).join(' | ')}');
    }
    final routes = routeCount.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    print('CHAOS-B|RESUMO| rotas: ${routes.map((e) => '${e.key}=${e.value}').join(' ')}');
    print('CHAOS-B|RESUMO| estatísticas: $statCount');
    for (final kind in firstBy.keys) {
      final m = await minimizeB(engine, firstBy[kind]!, kind, sw, sw.elapsedMilliseconds + 20000);
      final res = await runB(engine, fixed: m);
      final x = res.v.firstWhere((e) => e.kind == kind, orElse: () => VA(kind, '(não reproduziu)', -1));
      print('CHAOS-B|MIN| $kind (seed ${firstSeed[kind]}, ${m.length} turnos): ${m.map((e) => '"${e.text.replaceAll('\n', r'\n')}"').join(' ⏎ ')}  ⇒  ${x.detail}');
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}
