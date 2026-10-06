// Portão de qualidade do Item 2, lote A (PLANO_CESAR.md) — REVALIDAÇÃO r4
// da etapa 5, depois da 7e (rede de confirmação por certeza:
// `lib/ai/entry_certainty.dart` + 5º check do `EntrySafetyGate`).
//
// Frases INÉDITAS: cada literal de 4+ tokens a partir da marca "CASOS" tem
// Jaccard de tokens < 0,6 contra todos os literais de `test/**/*.dart` e os
// trechos de `docs/qa/*.md` — conferido por script antes de rodar (respostas
// curtas como "sim", "pix", "45" ficam de fora).
//
// Só imprime (nunca falha a suíte):
//   ACCD_FAIL|eixo|id|sev|entrada|esperado|obtido
//   ACCD_OK|eixo|id|entrada|obtido
//   ACCD_AXIS|eixo|passou/total|pct|confirmações
//   ACCD_TOTAL|passou/total|pct|sev
//
// Rodar:
//   flutter test test/_qa/acceptance_lote_a_r4_probe_test.dart 2>&1 | grep -E "ACCD_"
//
// `SimD` = `SimC` da r3 conferido contra o `_sendMessage` atual: a 7e passou o
// rascunho/lote pendente para `isCancelCommand(text, pending: …)` (o "não" ao
// "Registro assim?" descarta). A confirmação em si é o slot `confirm` do
// rascunho (motor: `EntrySafetyGate.checkCertainty`, `_confirmBatchIfUnsure`,
// `mergeDrafts`) — o chat não tem lógica própria para ela.
//
// Regras de pontuação da rede de confirmação:
// - "Registro assim?" mostrando o lançamento certo NÃO é P0 (o usuário vê e
//   decide); se mostra valor/tipo/data errado → P1.
// - Em frase clara (sem dúvida real) a confirmação é desnecessária → P2.
// - Eixo 7: 50 lançamentos claros; qualquer pergunta → P2. Meta ≤ 5%.
// Datas sempre relativas a DateTime.now().
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/goal_parser.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/persistence_service.dart';

import 'chaos_r3_support.dart' show R3Reply;

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

// ─────────────────────────── simulador do chat (ordem atual) ───────────────────────────

class SimD {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  FinancialTransactionDraft? active;
  FinancialTransactionDraft? last;
  List<String> lastIds = const [];
  List<FinancialTransactionDraft>? pendingBatch;
  static int _goalSeq = 0;

  SimD(this.engine, this.repo) : assistant = CesarAssistant(repository: repo, engine: engine);

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
      return;
    }
    if (last == null || !lastIds.any(reply.changedIds.contains)) return;
    final tx = repo.transactions.where((t) => t.id == lastIds.first).firstOrNull;
    if (tx == null) return;
    last = last!.copyWith(
      amount: tx.amount,
      category: tx.category,
      paymentMethod: tx.paymentMethod,
      installments: tx.installments,
      description: tx.title,
      intent: tx.type == TransactionType.income ? 'income' : (tx.type == TransactionType.transfer ? 'transfer' : 'expense'),
    );
  }

  R3Reply _send(String input) {
    var text = input;
    if (text.isEmpty) return R3Reply('empty_ignored', '(chat ignora mensagem vazia)');
    engine.setCustomCategories(repo.customCategoryNames);
    assistant.beginTurn();

    // 0. (7e) o rascunho pendente vai junto: "não" ao "Registro assim?" descarta.
    if (active != null && !active!.isComplete && engine.isCancelCommand(text, pending: active)) {
      active = null;
      return R3Reply('cancel_pending', 'Tudo bem, descartei esse lançamento. Nada foi registrado.');
    }

    if (pendingBatch != null) {
      final batch = pendingBatch!;
      final firstOpen = batch.firstWhere((d) => !d.isComplete, orElse: () => batch.first);
      if (engine.isCancelCommand(text, pending: firstOpen)) {
        pendingBatch = null;
        return R3Reply('cancel_pending', 'Tudo bem, descartei esses lançamentos. Nada foi registrado.');
      }
      final whatIf = assistant.hypothesisReply(text);
      if (whatIf != null) return R3Reply(whatIf.route, whatIf.text);
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
      repo.addGoal(FinancialGoal(id: 'goal-d-${++_goalSeq}', title: goalCreation.title, targetAmount: goalCreation.targetAmount, targetDate: goalCreation.targetDate));
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

    final draftPending = active != null && !active!.isComplete;
    if (!draftPending || engine.startsNewTransaction(active!, text)) {
      final multi = engine.parseMulti(text);
      if (multi.length >= 2) {
        final dropped = draftPending ? LocalFinancialNlpEngine.discardedDraftNotice(active!) : null;
        active = null;
        final prompt = engine.multiClarificationPrompt(multi);
        if (prompt == null) return _saveBatch(multi, notice: dropped);
        pendingBatch = multi;
        return R3Reply('ask_multi', dropped == null ? prompt : '$dropped\n\n$prompt');
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
          id: 'rem-d-${repo.reminders.length + 1}-${DateTime.now().microsecondsSinceEpoch}',
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

  R3Reply _saveBatch(List<FinancialTransactionDraft> drafts, {String? notice}) {
    for (final d in drafts) {
      _saved(repo.addTransactionFromDraft(d).map((t) => t.id).toList());
    }
    last = drafts.last;
    final body = 'Identifiquei ${drafts.length} lançamentos: ${drafts.map((d) => '${d.amount} ${d.description}').join('; ')}';
    return R3Reply('multi', notice == null ? body : '$notice\n\n$body');
  }
}

// ─────────────────────────── modelo ───────────────────────────

class Outcome {
  final String sev;
  final String got;
  Outcome(this.sev, this.got);
}

class Ctx {
  final SimD sim;
  final List<String> turns;
  final List<R3Reply> replies;
  final Map<String, String> before;
  final int remindersBefore;
  final List<String?> activeDesc;
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
  bool get everConfirmed => replies.any((r) => r.text.contains('Registro assim?'));

  String get pendingInfo {
    final a = sim.active;
    if (sim.pendingBatch != null) return 'lote pendente(${sim.pendingBatch!.map((d) => '${d.intent}/${d.amount}/${d.missingSlots}').join(';')})';
    if (a != null && !a.isComplete) return 'rascunho pendente ${a.intent} ${a.amount} off=${a.dateOffsetDays} "${a.description}" missing=${a.missingSlots}';
    return '';
  }

  String get summary {
    final add = added.map((t) => '+${t.type.name}:${t.amount}:${t.title}:${t.category}:${t.paymentMethod}:${_dm(t.date)}').join(', ');
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
  Case(this.axis, this.id, this.turns, this.expected, this.check, {this.settle = true});
}

// ─────────────────────────── datas (relativas a hoje) ───────────────────────────

final DateTime _now = DateTime.now();
DateTime get _today => DateTime(_now.year, _now.month, _now.day);
String _dm(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
int _offsetOf(DateTime d) => DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(_today.year, _today.month, _today.day)).inDays;
DateTime _at(int offset, [int hour = 12]) => DateTime(_today.year, _today.month, _today.day + offset, hour);

/// Última ocorrência (1–7 dias atrás) do dia da semana.
int backTo(int weekday) {
  var b = (_today.weekday - weekday) % 7;
  if (b == 0) b = 7;
  return -b;
}

/// "dia N" ao lançar: o dia N mais recente que já passou (este mês ou o anterior).
int dayN(int n) => _offsetOf(n <= _today.day ? DateTime(_today.year, _today.month, n) : DateTime(_today.year, _today.month - 1, n));
int lastMonthDay(int d) => _offsetOf(DateTime(_today.year, _today.month - 1, d));

bool _sameDay(DateTime a, int offset) {
  final e = DateTime(_today.year, _today.month, _today.day + offset);
  return a.year == e.year && a.month == e.month && a.day == e.day;
}

String _dayLabel(int offset) => _dm(_today.add(Duration(days: offset)));
int _domOf(int offset) => _today.add(Duration(days: offset)).day;

// ─────────────────────────── verificadores ───────────────────────────

Outcome _fail(String sev, Ctx c, [String note = '']) => Outcome(sev, '${note.isEmpty ? '' : '$note — '}${c.summary}');

String _fold(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[áàâã]'), 'a')
    .replaceAll(RegExp('[éê]'), 'e')
    .replaceAll('í', 'i')
    .replaceAll(RegExp('[óôõ]'), 'o')
    .replaceAll('ú', 'u')
    .replaceAll('ç', 'c');

List<String> _openSlots(Ctx c) {
  final a = c.sim.active;
  final out = <String>[];
  if (a != null && !a.isComplete) out.addAll(a.missingSlots);
  if (c.sim.pendingBatch != null) out.addAll(c.sim.pendingBatch!.where((d) => !d.isComplete).expand((d) => d.missingSlots));
  return out;
}

bool _confirming(Ctx c) => _openSlots(c).contains('confirm');

/// O que o César está mostrando no "Registro assim?".
List<FinancialTransactionDraft> _shown(Ctx c) {
  if (c.sim.pendingBatch != null) return c.sim.pendingBatch!;
  final a = c.sim.active;
  return a == null ? const [] : [a];
}

bool _askedType(Ctx c) {
  if (_openSlots(c).contains('type')) return true;
  final t = _fold(c.lastReply.text);
  return t.contains('entrou') && t.contains('saiu');
}

bool _generic(Ctx c) => c.lastReply.route == 'unknown' && c.lastReply.text.contains('gasto ou uma receita');
bool _askedDate(Ctx c) => _openSlots(c).contains('date');
bool _askedSplit(Ctx c) => _openSlots(c).contains('split') || _openSlots(c).contains('amount');

/// Confere o lançamento mostrado no "Registro assim?": errado → P1; certo e
/// [ok] → aceito; certo e não [ok] → confirmação desnecessária (P2).
Outcome? _judgeConfirm(Ctx c, Set<String> okTypes, double amount, Set<int>? days, bool anyDay, bool ok) {
  final s = _shown(c).where((d) => d.missingSlots.contains('confirm')).toList();
  if (s.length != 1) return _fail('P1', c, 'confirmação mostra ${s.length} itens');
  final d = s.single;
  if (!okTypes.contains(d.intent)) return _fail('P1', c, 'confirmação mostra tipo errado (${d.intent})');
  if (d.amount == null || (d.amount! - amount).abs() > 0.005) return _fail('P1', c, 'confirmação mostra valor errado (${d.amount})');
  if (!anyDay && !(days ?? {0}).contains(d.dateOffsetDays)) return _fail('P1', c, 'confirmação mostra data errada (${_dayLabel(d.dateOffsetDays)})');
  if (ok) return null;
  return _fail('P2', c, 'confirmação desnecessária ("Registro assim?") em frase clara');
}

/// Exatamente um lançamento novo, do tipo/valor dados; nada editado/apagado.
Check one(String type, double amount,
        {Set<String>? types,
        Set<int>? days,
        bool anyDay = false,
        bool askTypeOk = false,
        bool askDateOk = false,
        bool askSplitOk = false,
        bool? confirmOk,
        String? pay,
        String? notTitle}) =>
    (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
      final a = c.added;
      final okTypes = types ?? {type};
      if (a.isEmpty) {
        if (_confirming(c)) return _judgeConfirm(c, okTypes, amount, days, anyDay, confirmOk ?? askTypeOk);
        if (askTypeOk && _askedType(c)) return null;
        if (askDateOk && _askedDate(c)) return null;
        if (askSplitOk && _askedSplit(c)) return null;
        if (askTypeOk && _generic(c)) return _fail('P2', c, 'pergunta genérica (gasto ou receita?) e perde o valor');
        final miss = _openSlots(c);
        if (miss.isNotEmpty && miss.every((m) => m == 'type' || m == 'date' || m == 'split' || m == 'amount')) {
          return _fail('P2', c, 'pergunta desnecessária (${miss.join(',')})');
        }
        return _fail('P1', c, c.pendingInfo.isNotEmpty ? 'não registrou, ficou perguntando' : 'não registrou');
      }
      if (a.length > 1) {
        final sum = a.fold<double>(0, (s, t) => s + t.amount);
        return _fail('P0', c, 'registrou ${a.length} lançamentos (soma $sum)');
      }
      final t = a.single;
      if (!okTypes.contains(t.type.name)) return _fail('P0', c, 'tipo errado');
      if ((t.amount - amount).abs() > 0.005) return _fail('P0', c, 'valor errado');
      if (!anyDay) {
        final ds = days ?? {0};
        if (!ds.any((d) => _sameDay(t.date, d))) return _fail('P0', c, 'data errada (esperado ${ds.map(_dayLabel).join(' ou ')})');
      }
      if (pay != null && t.paymentMethod != pay) return _fail('P1', c, 'forma de pagamento ≠ $pay');
      if (notTitle != null && _fold(t.title).contains(notTitle)) return _fail('P1', c, 'herdou "$notTitle" do rascunho descartado');
      return null;
    };

Check income(double v, {bool askOk = false, Set<int>? days, bool? confirmOk}) =>
    one('income', v, askTypeOk: askOk, days: days, confirmOk: confirmOk);
Check expense(double v, {bool askOk = false, Set<int>? days, Set<String>? types, bool? confirmOk, bool askSplitOk = false}) =>
    one('expense', v, askTypeOk: askOk, days: days, types: types, confirmOk: confirmOk, askSplitOk: askSplitOk);

/// Direção ambígua: tem de perguntar "entrou ou saiu?"; gravar qualquer tipo é P0.
Outcome? askType(Ctx c) {
  if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
  if (c.added.isNotEmpty) return _fail('P0', c, 'assumiu a direção (${c.added.first.type.name}) sem perguntar');
  if (_askedType(c)) return null;
  if (_confirming(c)) return _fail('P1', c, 'mostrou como ${_shown(c).first.intent} no "Registro assim?" sem perguntar a direção');
  if (_generic(c)) return _fail('P2', c, 'pergunta genérica (gasto ou receita?) e perde o valor');
  return _fail('P1', c, 'não perguntou "entrou ou saiu?"');
}

/// Vários lançamentos; [types]: tipos aceitos por valor (na ordem de [amounts]).
Check many(List<double> amounts, {List<Set<String>>? types, List<int>? days, bool confirmOk = false}) => (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
      final a = c.added;
      if (a.isEmpty) {
        if (_confirming(c)) {
          final s = _shown(c);
          final got = s.map((d) => d.amount ?? -1).toList()..sort();
          final exp = [...amounts]..sort();
          final same = got.length == exp.length && List.generate(exp.length, (i) => (got[i] - exp[i]).abs() < 0.005).every((x) => x);
          if (!same) return _fail('P1', c, 'confirmação mostra itens ${got.join('+')} ≠ ${exp.join('+')}');
          return confirmOk ? null : _fail('P2', c, 'confirmação desnecessária do lote');
        }
        final miss = _openSlots(c);
        if (miss.isNotEmpty && miss.every((m) => m == 'type' || m == 'date' || m == 'split' || m == 'amount')) {
          return _fail('P2', c, 'pergunta desnecessária (${miss.join(',')})');
        }
        return _fail('P1', c, c.pendingInfo.isEmpty ? 'não registrou' : 'não registrou, ficou perguntando');
      }
      final got = a.map((t) => t.amount).toList()..sort();
      final exp = [...amounts]..sort();
      final same = got.length == exp.length && List.generate(exp.length, (i) => (got[i] - exp[i]).abs() < 0.005).every((x) => x);
      if (!same) return _fail('P0', c, 'itens ${got.join('+')} ≠ ${exp.join('+')}');
      for (var i = 0; i < amounts.length; i++) {
        final ok = types?[i] ?? {'expense'};
        if (!a.any((t) => (t.amount - amounts[i]).abs() < 0.005 && ok.contains(t.type.name))) return _fail('P0', c, 'tipo errado no item ${amounts[i]}');
        final d = days?[i] ?? 0;
        if (!a.any((t) => (t.amount - amounts[i]).abs() < 0.005 && _sameDay(t.date, d))) {
          return _fail('P0', c, 'data errada no item ${amounts[i]} (esperado ${_dayLabel(d)})');
        }
      }
      if (types == null && a.any((t) => t.type == TransactionType.transfer)) return _fail('P2', c, 'item virou transferência');
      if (a.any((t) => t.paymentMethod == 'unknown')) return _fail('P2', c, 'item sem forma de pagamento');
      return null;
    };

/// Valor incerto (2 números para um item): não grava; pergunta.
Outcome? noRecordAsks(Ctx c) {
  if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
  if (c.added.isNotEmpty) return _fail('P0', c, 'gravou valor escolhido em silêncio');
  if (_confirming(c)) return _fail('P1', c, 'mostrou UM valor escolhido no "Registro assim?" em vez de perguntar qual');
  if (c.pendingInfo.isEmpty) return _fail('P2', c, 'não ficou perguntando');
  return null;
}

/// Hipótese / intenção / obrigação / não-evento: nada gravado nem alterado.
Outcome? noEntry(Ctx c) {
  if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'gravou/alterou dados');
  if (_confirming(c)) return _fail('P2', c, 'mostrou como lançamento ("Registro assim?") algo que não aconteceu');
  if (c.pendingInfo.isNotEmpty) return _fail('P1', c, 'tratou como lançamento (rascunho pendente)');
  if (_generic(c)) return _fail('P2', c, 'não entendeu a hipótese (resposta genérica)');
  if (c.lastReply.route.startsWith('report')) return _fail('P2', c, 'respondeu com relatório sem sentido');
  return null;
}

/// Data futura: não grava; pergunta a data, cria lembrete ou trata como plano.
Outcome? futureAsks(Ctx c) {
  if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
  if (c.added.isNotEmpty) return _fail('P0', c, 'gravou com data ${_dm(c.added.first.date)} sem perguntar');
  if (_askedDate(c)) return null;
  if (c.repo.reminders.length > c.remindersBefore) return null;
  if (_confirming(c)) {
    final d = _shown(c).first;
    return _fail('P1', c, 'confirmação mostra data ${_dayLabel(d.dateOffsetDays)} para algo dito no futuro');
  }
  if (c.lastReply.route == 'unknown' && _fold(c.lastReply.text).contains('plano')) return null;
  return _fail('P1', c, 'não perguntou a data');
}

Check recurring(String type, double amount, int due) => (c) {
      final a = c.added;
      if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
      if (a.isEmpty) {
        if (_confirming(c)) return _judgeConfirm(c, {type}, amount, null, true, false);
        final miss = _openSlots(c);
        return _fail(miss.isNotEmpty && !miss.contains('amount') ? 'P2' : 'P1', c, miss.contains('amount') ? 'perdeu o valor dito' : 'não registrou');
      }
      if (a.length > 1) return _fail('P0', c, 'registrou ${a.length}');
      if (a.single.type.name != type) return _fail('P0', c, 'tipo errado');
      if ((a.single.amount - amount).abs() > 0.005) return _fail('P0', c, 'valor errado');
      final d = c.sim.last;
      if (d == null || !d.isRecurrent) return _fail('P0', c, 'virou lançamento único (recorrência perdida)');
      if (d.dueDay != due) return _fail('P0', c, 'dia de vencimento ${d.dueDay} ≠ $due');
      return null;
    };

Check onceOn(String type, double amount, Set<int> days, {bool askDateOk = false, bool askTypeOk = false, bool? confirmOk}) => (c) {
      final base = one(type, amount, days: days, askDateOk: askDateOk, askTypeOk: askTypeOk, confirmOk: confirmOk)(c);
      if (base != null) return base;
      final d = c.sim.last;
      if (c.added.isNotEmpty && d != null && d.isRecurrent) return _fail('P1', c, 'virou recorrente');
      return null;
    };

Check weekend(String type, double amount) => (c) {
      final base = one(type, amount, days: {backTo(DateTime.saturday)}, askDateOk: true)(c);
      if (base != null) return base;
      if (c.added.isEmpty) return null;
      final note = c.sim.last?.assumptionNote ?? '';
      if (!note.contains('sábado') && !c.allText.contains('sábado')) return _fail('P2', c, 'gravou no sábado sem avisar');
      return null;
    };

Outcome? nothingSaved(Ctx c) {
  if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'gravou/alterou dados');
  return null;
}

/// Nada gravado e nada pendente (o "não"/cancelar encerrou o assunto).
Outcome? closedNothing(Ctx c) {
  final o = nothingSaved(c);
  if (o != null) return o;
  if (c.pendingInfo.isNotEmpty) return _fail('P1', c, 'rascunho continua pendente');
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

/// Pergunta no meio: respondida, nada gravado, sem ficar perguntando slot.
Outcome? answeredNoSave(Ctx c) {
  final o = nothingSaved(c);
  if (o != null) return o;
  final r = c.lastReply.route;
  if (r == 'ask' || r == 'saved' || r == 'unknown') return _fail('P1', c, 'pergunta não respondida (rota $r)');
  return null;
}

// ── eixo 6 (registros relativos a hoje) ──

FinancialTransaction _tx(String id, String title, double amount, int offset, String cat) =>
    FinancialTransaction(id: id, title: title, amount: amount, type: TransactionType.expense, category: cat, paymentMethod: 'pix', date: _at(offset));

final int _sat = backTo(DateTime.saturday);
final int _fri = backTo(DateTime.friday);
final int _mon = backTo(DateTime.monday);
final int _sun = backTo(DateTime.sunday);
final int _tue = backTo(DateTime.tuesday);
final int _thu = backTo(DateTime.thursday);
final int _wed = backTo(DateTime.wednesday);
const int _oticOff = -9;
const int _clinOff = -18;

List<FinancialTransaction> _seed6() => [
      _tx('lav', 'Lava Jato', 35, _sat, 'transport'),
      _tx('sorv', 'Sorveteria', 24, _sun, 'leisure'),
      _tx('drog', 'Drogaria', 67, _tue, 'health'),
      _tx('ofi', 'Oficina', 420, _mon, 'transport'),
      _tx('acad', 'Academia', 110, _wed, 'health'),
      _tx('pzd', 'Pizzaria Domingo', 78, _fri, 'leisure'),
      _tx('posto', 'Posto Shell', 180, _mon, 'transport'),
      _tx('uber1', 'Uber', 22, _tue, 'transport'),
      _tx('uber2', 'Uber', 19, _sat, 'transport'),
      _tx('otic', 'Ótica', 350, _oticOff, 'health'),
      _tx('cin', 'Cinema', 60, 0, 'leisure'),
      _tx('merc', 'Mercado Bom Preço', 210, _thu, 'supermarket'),
      _tx('clin', 'Clínica Sorriso', 280, _clinOff, 'health'),
    ];

const _seedTitles = {
  'lav': 'Lava Jato', 'sorv': 'Sorveteria', 'drog': 'Drogaria', 'ofi': 'Oficina', 'acad': 'Academia', 'pzd': 'Pizzaria Domingo',
  'posto': 'Posto Shell', 'otic': 'Ótica', 'cin': 'Cinema', 'merc': 'Mercado Bom Preço', 'clin': 'Clínica Sorriso',
};

/// Título de um registro semeado que está numa data (para nomear distratores).
String? _titleOn(int offset, {String? except}) {
  for (final t in _seed6()) {
    if (t.title == except) continue;
    if (_sameDay(t.date, offset)) return t.title;
  }
  return null;
}

Check untouched(String title, {String? distractor}) => (c) {
      if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou dados sem confirmação');
      if (c.pendingInfo.isNotEmpty) return _fail('P1', c, 'virou lançamento novo pendente');
      if (distractor != null && c.allText.contains(distractor)) return _fail('P2', c, 'ofereceu o distrator $distractor');
      if (!c.allText.contains(title)) return _fail('P2', c, 'não sugeriu $title');
      return null;
    };

/// Edição com o nome FORA do título (decisão do usuário): não muda nada e
/// mostra o item certo perguntando se é esse.
Check confirmsShowing(String title, {List<String> notTitles = const []}) => (c) {
      if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou sem confirmar (nome fora do título)');
      if (c.pendingInfo.isNotEmpty) return _fail('P1', c, 'virou lançamento novo pendente');
      for (final n in notTitles) {
        if (c.lastReply.text.contains(n)) return _fail('P1', c, 'mostrou o item errado ($n)');
      }
      if (!c.lastReply.text.contains(title)) return _fail('P1', c, 'não mostrou $title');
      return null;
    };

Check onlyThis(String id, {bool deleted = false, bool Function(FinancialTransaction t)? ok, bool askOk = false, double? newAmount}) => (c) {
      final adds = c.added;
      if (newAmount == null && adds.isNotEmpty) return _fail('P0', c, 'criou lançamento novo');
      if (newAmount != null && (adds.length != 1 || (adds.single.amount - newAmount).abs() > 0.005)) {
        return _fail('P0', c, 'lançamento novo deveria ser só $newAmount');
      }
      final others = [...c.removed, ...c.changed].where((x) => x != id).toList();
      if (others.isNotEmpty) return _fail('P0', c, 'mexeu em $others');
      if (c.removed.isEmpty && c.changed.isEmpty) {
        final r = c.lastReply.route;
        final asking = const {'ask_correction_or_new', 'confirm', 'choose', 'not_found', 'ask_changes'}.contains(r);
        final title = _seedTitles[id];
        if (asking && title != null && c.lastReply.text.contains(title)) {
          return askOk ? null : _fail('P2', c, 'pediu confirmação desnecessária (nome está no título)');
        }
      }
      if (deleted) {
        if (!c.removed.contains(id)) return _fail('P1', c, 'não apagou $id');
        return null;
      }
      if (!c.changed.contains(id)) return _fail('P1', c, 'não alterou $id');
      if (ok != null && !ok(c.byId(id)!)) return _fail('P0', c, 'alterou $id com valor errado');
      return null;
    };

Outcome? existingIntact(Ctx c) {
  if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
  return null;
}

Check noWrongDelete(String? distractor) => (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty || c.added.isNotEmpty) return _fail('P0', c, 'mudou dados');
      if (c.firstReply.route == 'confirm_delete') return _fail('P0', c, 'pediu confirmação para apagar outro registro');
      if (distractor != null && c.firstReply.text.contains(distractor)) return _fail('P2', c, 'citou o distrator $distractor');
      return null;
    };

// ─── CASOS ───

List<Case> buildCases() {
  final cs = <Case>[];
  void add(int axis, String id, List<String> turns, String exp, Check chk, {bool settle = true}) =>
      cs.add(Case(axis, id, turns, exp, chk, settle: settle));

  // ── Eixo 1: direção do dinheiro ──
  add(1, 'in1', ['pingou 1.180 do auxílio na conta hj cedinho'], 'receita 1180', income(1180));
  add(1, 'in2', ['a freguesa do bolo de pote me mandou 96 no pix'], 'receita 96', income(96));
  add(1, 'in3', ['tia neide mandou cento e vinte pra me ajudar com as contas'], 'receita 120 (voz)', income(120));
  add(1, 'in4', ['chegou o reembolso da passagem aérea, 340 no pix'], 'receita 340', income(340));
  add(1, 'in5', ['caiu o pix do brechó, desapeguei de umas roupas por 75'], 'receita 75', income(75));
  add(1, 'in6', ['o rapaz da oficina me devolveu 40 de troco que tinha ficado com ele'], 'receita 40', income(40));
  add(1, 'in7', ['faturei 260 fazendo frete com a kombi hoje'], 'receita 260', income(260));
  add(1, 'in8', ['meu padrinho me deu 500 de formatura, em especie'], 'receita 500', income(500));
  add(1, 'in9', ['rendeu 31,20 a poupança esse mês, caiu agora'], 'receita 31,20', income(31.2));
  add(1, 'in10', ['recebi 180 pela aula particular de violão do lucas'], 'receita 180', income(180));
  add(1, 'in11', ['o inquilino da edícula depositou oitocentos reais hoje'], 'receita 800 (voz)', income(800));
  add(1, 'in12', ['ganhei 50 conto na raspadinha kkkk'], 'receita 50', income(50));
  add(1, 'in13', ['restituição do imposto de renda caiu hj, 1.430'], 'receita 1430', income(1430));
  add(1, 'in14', ['a firma me reembolsou 212 de combustível das visitas'], 'receita 212', income(212));
  add(1, 'in15', ['uai sô, o compadre me pagou os 150 que tava devendo'], 'receita 150', income(150));
  add(1, 'in16', ['pagaram meu cachê de 350 da apresentação no casamento'], 'receita 350', income(350));
  // Direção dita pelo outro lado.
  add(1, 'rev1', ['a diarista recebeu 160 de mim hoje de manhã'], 'despesa 160 ou pergunta (nunca receita)', expense(160, askOk: true));
  add(1, 'rev2', ['o flanelinha levou 5 meu na frente do banco'], 'despesa 5 ou pergunta', expense(5, askOk: true));
  add(1, 'rev3', ['meu sobrinho me pagou 45 da camiseta do time que eu trouxe'], 'receita 45', income(45, askOk: true));
  add(1, 'rev4', ['o salão cobrou 85 de mim pela escova progressiva'], 'despesa 85', expense(85, askOk: true));
  add(1, 'rev5', ['a loja de material ganhou 420 de mim com esse piso'], 'despesa 420 ou pergunta (nunca receita)', expense(420, askOk: true));
  add(1, 'rev6', ['o dono da república recebeu meu aluguel de 700 em mãos'], 'despesa 700 ou pergunta (nunca receita)', expense(700, askOk: true));
  add(1, 'rev7', ['a vizinha do 12 acertou comigo os 30 do bolo'], 'receita 30 ou pergunta', income(30, askOk: true));
  // Despesa óbvia.
  add(1, 'out1', ['larguei 64 no posto completando o tanque, débito'], 'despesa 64', expense(64));
  add(1, 'out2', ['meti 120 numa jaqueta lá no brás, dinheiro'], 'despesa 120', expense(120));
  add(1, 'out3', ['quitei a autoescola, 380 no pix'], 'despesa 380', expense(380));
  add(1, 'out4', ['foi 47,80 o sacolão de hoje no débito'], 'despesa 47,80', expense(47.8));
  add(1, 'out5', ['gastei mil e cem reais no conserto do câmbio'], 'despesa 1100 (voz)', expense(1100));
  add(1, 'out6', ['comprei o material escolar da criançada, 315 no crédito à vista'], 'despesa 315', expense(315));
  add(1, 'out7', ['a mensalidade do judô saiu 140 no débito'], 'despesa 140', expense(140));
  add(1, 'out8', ['apliquei 200 no tesouro selic hoje pelo app'], 'despesa/transferência 200 (ou pergunta)',
      expense(200, types: {'expense', 'transfer'}, askOk: true));
  // Armadilhas.
  add(1, 'trap1', ['recebi a fatura do nubank de 1.240 e já quitei pelo app'], 'despesa 1240 (fatura recebida ≠ dinheiro recebido)',
      expense(1240, askOk: true));
  add(1, 'trap2', ['ganhei uma multa de 130 por parar em fila dupla'], 'despesa 130 ou pergunta (nunca receita)', expense(130, askOk: true));
  add(1, 'trap3', ['recebi o boleto do gás encanado 115 e paguei na hora'], 'despesa 115', expense(115, askOk: true));
  add(1, 'trap4', ['consegui 30 de desconto e paguei 170 no óculos no pix'], 'despesa 170 (desconto não é valor)', expense(170, askOk: true));
  add(1, 'trap5', ['o caixa eletrônico engoliu 100 meu e não devolveu'], 'despesa 100 ou pergunta (nunca receita)', expense(100, askOk: true));
  add(1, 'trap6', ['me cobraram 25 de taxa de entrega no ifood, absurdo'], 'despesa 25', expense(25));
  add(1, 'trap7', ['entrou na minha fatura uma compra de 89 da shein'], 'despesa 89 ou pergunta (nunca receita)', expense(89, askOk: true));
  add(1, 'trap8', ['recebi cobrança de 60 da operadora de tv e já paguei'], 'despesa 60', expense(60, askOk: true));
  // Ambíguo: tem de perguntar.
  add(1, 'amb1', ['rolou um pix de 300 com o jonas'], 'pergunta "entrou ou saiu?"', askType, settle: false);
  add(1, 'amb2', ['transação de 220 com o primo do zé'], 'pergunta "entrou ou saiu?"', askType, settle: false);
  add(1, 'amb3', ['movimentei 90 com a ana hoje cedo'], 'pergunta "entrou ou saiu?"', askType, settle: false);
  add(1, 'amb4', ['180 vizinho de baixo pix'], 'pergunta "entrou ou saiu?"', askType, settle: false);
  add(1, 'amb5', ['fiz um rolo de 250 com o cara do celular'], 'pergunta "entrou ou saiu?"', askType, settle: false);

  // ── Eixo 2: multi-lançamento e números que não são valor ──
  add(2, 'm1', ['pastel 12 e caldo de cana 8 na feira, dinheiro'], '2 despesas 12+8', many([12, 8]));
  add(2, 'm2', ['gastei 33 na drogaria e 18 na panificadora hj, tudo no débito'], '2 despesas 33+18', many([33, 18]));
  add(2, 'm3', ['pedágio 7,40 na ida e 7,40 na volta no cartão de débito'], '2 despesas iguais 7,40+7,40', many([7.4, 7.4]));
  add(2, 'm4', ['recebi 250 da faxina e 120 de passar roupa no pix'], '2 receitas 250+120',
      many([250, 120], types: [{'income'}, {'income'}]));
  add(2, 'm5', ['corte 40 barba 25 no salão do bairro pix'], '2 despesas 40+25', many([40, 25]));
  add(2, 'm6', ['luz 187 água 64 internet 99 tudo boleto'], '3 despesas 187+64+99', many([187, 64, 99]));
  add(2, 'm7', ['paguei 15 no estacionamento e mais 42 no almoço executivo, pix'], '2 despesas 15+42', many([15, 42]));
  add(2, 'm8', ['uber pra ir 18 e pra voltar 23, tudo no pix'], '2 despesas 18+23', many([18, 23]));
  add(2, 'm9', ['vendi o sofá velho por 600 e comprei uma estante de 350 no pix'], 'receita 600 + despesa 350',
      many([600, 350], types: [{'income'}, {'expense'}]));
  add(2, 'm10', ['sorvete das crianças 26, pipoca 14 em dinheiro'], '2 despesas 26+14', many([26, 14]));
  add(2, 'm11', ['remédio da pressão 58 e fralda geriátrica 72, débito'], '2 despesas 58+72', many([58, 72]));
  add(2, 'm12', ['ontem pizza 70 e hoje açaí 22 no pix'], '70 ontem + 22 hoje', many([70, 22], days: [-1, 0]));
  add(2, 'm13', ['trinta e cinco no mercadinho e doze na banca de jornal tudo no pix'], '2 despesas 35+12 (voz)', many([35, 12]));
  add(2, 'm14', ['gasolina 150 no crédito à vista e calibragem 5 no dinheiro'], '2 despesas 150+5', many([150, 5]));
  add(2, 'm15', ['paguei 260 da escola de inglês e 90 do livro didático, boleto'], '2 despesas 260+90', many([260, 90]));
  add(2, 'm16', ['presente da afilhada 80 e cartãozinho 9, crédito à vista'], '2 despesas 80+9', many([80, 9]));
  add(2, 'm17', ['dei 20 pro guardador de carro e 10 pro rapaz do sinal, dinheiro'], '2 despesas 20+10', many([20, 10]));
  add(2, 'm18', ['mandei 100 pra minha mãe e 100 pro meu irmão no pix'], '2 saídas 100+100',
      many([100, 100], types: [{'expense', 'transfer'}, {'expense', 'transfer'}]));
  // Números que não são valor.
  add(2, 's1', ['paguei 89 na botina número 41 no pix'], 'UM lançamento de 89', expense(89));
  add(2, 's2', ['comprei 3 dúzias de ovo caipira por 42 no dinheiro'], 'UM lançamento de 42', expense(42));
  add(2, 's3', ['gastei 130 no presente de bodas de 25 anos dos meus pais, pix'], 'UM lançamento de 130', expense(130));
  add(2, 's4', ['troquei o botijão de 13 kg, 125 no pix'], 'UM lançamento de 125', expense(125));
  add(2, 's5', ['paguei 18 no corte do cabelo do caçula de 6 anos, dinheiro'], 'UM lançamento de 18', expense(18));
  add(2, 's6', ['abasteci 40 litros e deu 236 no débito'], 'UM lançamento de 236', expense(236));
  add(2, 's7', ['comprei 2 ingressos pro clássico por 160 no pix'], 'UM lançamento de 160', expense(160));
  add(2, 's8', ['rachamos a conta numa mesa de 4 pessoas e minha parte deu 75 no pix'], 'UM lançamento de 75', expense(75));
  add(2, 's9', ['paguei o condomínio do bloco 7 apto 52, 480 no boleto'], 'UM lançamento de 480', expense(480));
  add(2, 's10', ['comprei um monitor de 27 polegadas por 1.150 no crédito em 5x'], 'UM lançamento de 1150', expense(1150));
  add(2, 's11', ['gastei 44 no rodízio de massa às 8 da noite, pix'], 'UM lançamento de 44', expense(44));
  add(2, 's12', ['comprei dipirona de 500 mg por 23 no pix'], 'UM lançamento de 23', expense(23));
  add(2, 's13', ['adiantei 2 meses de academia, 220 no pix'], 'UM lançamento de 220', expense(220));
  add(2, 's14', ['paguei 39,90 no plano de 20 giga do celular no débito'], 'UM lançamento de 39,90', expense(39.9));
  add(2, 's15', ['comprei uma bike aro 29 por 1.800 no crédito em 10x'], 'UM lançamento de 1800', expense(1800));
  add(2, 's16', ['paguei 150 no exame de sangue do laboratório da rua 15, pix'], 'UM lançamento de 150', expense(150));
  add(2, 's17', ['comprei 5 pães franceses a 1,20 cada no dinheiro'], 'UM lançamento de 6 (5 × 1,20)', expense(6));
  add(2, 's18', ['peguei 2 hambúrgueres artesanais por 58 no pix'], 'UM lançamento de 58', expense(58));
  add(2, 's19', ['gastei 70 na loja de 1,99 do centro no dinheiro'], 'UM lançamento de 70', expense(70));
  add(2, 's20', ['fiz a revisão dos 10 mil km, 120 no pix'], 'UM lançamento de 120', expense(120));
  add(2, 's21', ['paguei 250 numa caixa de som de 100 watts no pix'], 'UM lançamento de 250', expense(250));
  add(2, 's22', ['paguei 66 no buffet por quilo, prato de 0,8 kg, no débito'], 'UM lançamento de 66', expense(66));
  add(2, 's23', ['comprei a capinha do iphone 13 por 35 no pix'], 'UM lançamento de 35', expense(35));
  // Valor incerto.
  add(2, 'r1', ['paguei sei lá, 40 ou 45 no barbeiro, pix'], 'dois valores: pergunta, não grava', noRecordAsks, settle: false);
  add(2, 'r2', ['foi uns 90 a 100 o conserto da torneira, pix'], 'faixa: pergunta, não grava', noRecordAsks, settle: false);
  add(2, 'r3', ['gastei uns 30 e poucos no lanche da tarde, pix'], '30 (ou pergunta)', one('expense', 30, askSplitOk: true, confirmOk: true));
  add(2, 'r4', ['deu 200 e alguma coisa o rancho do mês, débito'], '200 (ou pergunta)', one('expense', 200, askSplitOk: true, confirmOk: true));

  // ── Eixo 3: hipótese / intenção / obrigação / não-evento × fato ──
  const irreal = [
    'se eu parcelar um sofá de 2400 em 12x, cabe no orçamento?',
    'imagina se eu torrasse 800 em roupa esse mês',
    'tô pensando em pegar um curso de 900 de excel',
    'preciso pagar 230 do dentista até sexta',
    'tenho que transferir 400 do aluguel amanhã cedo',
    'amanhã vou gastar uns 60 no cabeleireiro',
    'semana que vem recebo 2.100 do décimo terceiro',
    'quero comprar um celular de 1.700 na black friday',
    'bora gastar 100 no karaokê sábado?',
    'será que compensa pagar 320 no seguro do celular?',
    'e se eu vender o carro por 35 mil?',
    'hipoteticamente, se eu ganhar 5000 de bônus, quanto guardo?',
    'falta pagar 89 da internet desse mês',
    'ainda vou receber 450 do bico de pintura',
    'meu marido quer gastar 1.500 numa tv nova',
    'vale a pena gastar 400 numa cadeira gamer?',
    'daqui a pouco passo no mercado e devo gastar uns 200',
    'vou ter que desembolsar 600 no conserto do telhado',
    'minha meta é não passar de 300 em delivery',
    'o orçamento do pedreiro veio 4.800, tô pensando',
  ];
  for (var i = 0; i < irreal.length; i++) {
    add(3, 'irr${i + 1}', [irreal[i]], 'não grava; responde a hipótese/intenção/obrigação', noEntry);
  }
  const nonEvents = [
    'o pix de 150 pro eletricista voltou, não caiu',
    'tentei pagar 80 no débito mas o cartão recusou',
    'cancelei a compra de 260 na shopee antes de pagar',
    'quase gastei 300 num relógio, ainda bem que me segurei',
    'era pra eu ter pago 110 de luz ontem e esqueci',
    'o cliente prometeu 500 mas até agora nada',
    'não comprei a passagem de 420 ainda',
    'desisti do celular de 1.900, vou ficar com o velho mesmo',
    'me ofereceram 700 pelo notebook mas não vendi',
    'o boleto de 340 da faculdade ainda não venceu',
  ];
  for (var i = 0; i < nonEvents.length; i++) {
    add(3, 'non${i + 1}', [nonEvents[i]], 'não aconteceu: não grava', noEntry);
  }
  add(3, 'f1', ['se não me engano a pizza de ontem foi 58, paguei no pix'], 'despesa 58 ontem', expense(58, days: {-1}, confirmOk: true));
  add(3, 'f2', ['eu ia pegar ônibus mas peguei um 99 de 27 no pix'], 'despesa 27', expense(27));
  add(3, 'f3', ['tinha jurado economizar, mas gastei 140 em sapato no crédito à vista'], 'despesa 140', expense(140));
  add(3, 'f4', ['quando fui ver já tinha pago 66 de estacionamento no pix'], 'despesa 66', expense(66));
  add(3, 'f5', ['vou te falar uma coisa, recebi 300 de gorjeta no pix'], 'receita 300', income(300));
  add(3, 'f6', ['precisei pagar 95 de guincho no pix'], 'despesa 95', expense(95));
  add(3, 'f7', ['tive que comprar um pneu de 380 no crédito à vista'], 'despesa 380', expense(380));
  add(3, 'f8', ['queria só um cafezinho mas gastei 34 na padaria no pix'], 'despesa 34', expense(34));
  add(3, 'f9', ['caso queira saber, paguei 210 no conserto da geladeira no pix'], 'despesa 210', expense(210));
  add(3, 'f10', ['planejava gastar 50 e acabei gastando 85 no mercado no pix'], 'despesa 85 (50 era plano) ou pergunta',
      expense(85, askSplitOk: true, confirmOk: true));
  add(3, 'f11', ['se alguém perguntar, paguei 45 na rifa da igreja no dinheiro'], 'despesa 45', expense(45));
  add(3, 'f12', ['mesmo sem precisar comprei um fone de 99 no pix'], 'despesa 99', expense(99));
  add(3, 'f13', ['era pra ser rapidinho, mas o mecânico cobrou 450 no pix'], 'despesa 450', expense(450));
  add(3, 'f14', ['achei que não ia rolar, mas recebi os 800 do freela no pix'], 'receita 800', income(800));
  add(3, 'f15', ['devia ter esperado a promoção, paguei 299 no tênis no débito'], 'despesa 299', expense(299));
  add(3, 'f16', ['acabei pagando 72 de taxa no cartório em dinheiro'], 'despesa 72', expense(72));

  // ── Eixo 4: datas e recorrência ──
  add(4, 'd1', ['antes de ontem paguei 49 no açaí, pix'], 'despesa 49 anteontem', onceOn('expense', 49, {-2}));
  add(4, 'd2', ['ontem à tarde recebi 230 de uma faxina, pix'], 'receita 230 ontem', onceOn('income', 230, {-1}));
  add(4, 'd3', ['hj cedinho paguei 11 no pão e leite, dinheiro'], 'despesa 11 hoje', onceOn('expense', 11, {0}));
  add(4, 'd4', ['há três dias paguei 140 no pediatra no pix'], 'despesa 140 há 3 dias', onceOn('expense', 140, {-3}));
  add(4, 'd5', ['faz uma semana comprei um tênis de 260 no pix'], 'despesa 260 há 7 dias (ou pergunta)', onceOn('expense', 260, {-7}, askDateOk: true));
  add(4, 'd6', ['tem 5 dias que paguei 35 no chaveiro, dinheiro'], 'despesa 35 há 5 dias', onceOn('expense', 35, {-5}));
  add(4, 'd7', ['na segunda gastei 52 no sushi, pix'], 'despesa 52 segunda ${_dayLabel(_mon)}', onceOn('expense', 52, {_mon}));
  add(4, 'd8', ['sábado passado paguei 120 no rodízio, pix'], 'despesa 120 sábado (${_dayLabel(_sat)}/${_dayLabel(_sat - 7)}) ou pergunta',
      onceOn('expense', 120, {_sat, _sat - 7}, askDateOk: true));
  add(4, 'd9', ['no domingo de manhã recebi 90 de um bico, pix'], 'receita 90 domingo ${_dayLabel(_sun)}', onceOn('income', 90, {_sun}));
  add(4, 'd10', ['terça feira gastei 28 de mototáxi, dinheiro'], 'despesa 28 terça ${_dayLabel(_tue)}', onceOn('expense', 28, {_tue}));
  add(4, 'd11', ['quarta passada paguei 75 no cabeleireiro, pix'], 'despesa 75 quarta (${_dayLabel(_wed)}/${_dayLabel(_wed - 7)}) ou pergunta',
      onceOn('expense', 75, {_wed, _wed - 7}, askDateOk: true));
  add(4, 'd12', ['dia 25 paguei 340 da parcela do carro no boleto'], 'despesa única 340 em ${_dayLabel(dayN(25))}',
      onceOn('expense', 340, {dayN(25)}));
  add(4, 'd13', ['no dia 30 recebi 1.200 de comissão no pix'], 'receita 1200 em ${_dayLabel(dayN(30))}', onceOn('income', 1200, {dayN(30)}));
  add(4, 'd14', ['comprei uma blusa de 79 no dia 26, pix'], 'despesa 79 em ${_dayLabel(dayN(26))}', onceOn('expense', 79, {dayN(26)}));
  add(4, 'd15', ['dia 3 do mês passado paguei 210 de dentista, pix'], 'despesa 210 em ${_dayLabel(lastMonthDay(3))}',
      onceOn('expense', 210, {lastMonthDay(3)}));
  add(4, 'd16', ['dia quinze do mês passado recebi quatrocentos do aluguel do box'], 'receita 400 em ${_dayLabel(lastMonthDay(15))} (voz)',
      onceOn('income', 400, {lastMonthDay(15)}));
  add(4, 'd17', ['mês passado, dia 9, paguei 98 de gás no pix'], 'despesa 98 em ${_dayLabel(lastMonthDay(9))}',
      onceOn('expense', 98, {lastMonthDay(9)}));
  add(4, 'd18', ['em ${_dayLabel(-4)} gastei 66 no açougue, pix'], 'despesa 66 em ${_dayLabel(-4)}', onceOn('expense', 66, {-4}));
  add(4, 'd19', ['semana passada na sexta paguei 45 no boteco, pix'], 'despesa 45 sexta (${_dayLabel(_fri)}/${_dayLabel(_fri - 7)}) ou pergunta',
      onceOn('expense', 45, {_fri, _fri - 7}, askDateOk: true));
  add(4, 'd20', ['ontem de madrugada paguei 32 de uber pra voltar da festa, pix'], 'despesa 32 ontem', onceOn('expense', 32, {-1}));
  add(4, 'd21', ['agora há pouco paguei 19 no sorvete, pix'], 'despesa 19 hoje', onceOn('expense', 19, {0}));
  add(4, 'd22', ['hoje me toquei que paguei 58 de farmácia ontem, pix'], 'despesa 58 ontem', onceOn('expense', 58, {-1}, askDateOk: true));
  add(4, 'd23', ['gastei 27 na padaria da rua 7 de setembro no pix'], 'despesa 27 hoje (endereço) ou pergunta',
      onceOn('expense', 27, {0}, askDateOk: true));
  add(4, 'd24', ['paguei 89 de luz no dia 22 no boleto'], 'despesa única 89 em ${_dayLabel(dayN(22))}', onceOn('expense', 89, {dayN(22)}));
  add(4, 'd25', ['tava voltando do trampo anteontem e parei pra abastecer, 180 no débito'], 'despesa 180 anteontem',
      onceOn('expense', 180, {-2}));
  add(4, 'd26', ['quinta retrasada gastei 63 no petshop, pix'], 'despesa 63 quinta retrasada (ou pergunta)',
      onceOn('expense', 63, {_thu - 7, _thu - 14, _thu}, askDateOk: true));
  // Futuro: não grava.
  add(4, 'fut1', ['paguei 80 de pilates na quinta que vem, pix'], 'data futura: pergunta/não grava', futureAsks);
  add(4, 'fut2', ['gastei 45 no salão depois de amanhã, pix'], 'data futura: pergunta/não grava', futureAsks);
  add(4, 'fut3', ['recebi 600 do freela na semana que vem, pix'], 'data futura: pergunta/não grava', futureAsks);
  add(4, 'fut4', ['paguei 200 de iptu dia 20 do mês que vem, boleto'], 'data futura: pergunta/não grava', futureAsks);
  add(4, 'fut5', ['gastei 30 no lava jato amanhã cedo, pix'], 'data futura: pergunta/não grava', futureAsks);
  add(4, 'fut6', ['no próximo domingo recebi 100 de rifa, pix'], 'data futura: pergunta/não grava', futureAsks);
  add(4, 'wknd', ['torrei 140 no fds com churrasco, pix'], 'sábado + aviso (decisão do usuário)', weekend('expense', 140));
  // Recorrência.
  add(4, 'rec1', ['pago 79,90 de internet todo dia 15 no boleto'], 'recorrente despesa 79,90 dia 15', recurring('expense', 79.9, 15));
  add(4, 'rec2', ['todo dia 10 cai 1.800 da minha aposentadoria'], 'recorrente receita 1800 dia 10', recurring('income', 1800, 10));
  add(4, 'rec3', ['a escolinha de futebol é 120 por mês, vence dia 8'], 'recorrente despesa 120 dia 8', recurring('expense', 120, 8));
  add(4, 'rec4', ['recebo 650 do aluguel da garagem todo dia 20'], 'recorrente receita 650 dia 20', recurring('income', 650, 20));
  add(4, 'rec5', ['assinatura do spotify 21,90 todo dia 4 no crédito'], 'recorrente despesa 21,90 dia 4', recurring('expense', 21.9, 4));
  add(4, 'rec6', ['mensalidade do clube 95, vence todo dia 12, boleto'], 'recorrente despesa 95 dia 12', recurring('expense', 95, 12));
  add(4, 'rec7', ['pago 350 de pensão alimentícia todo dia 5 no pix'], 'recorrente despesa 350 dia 5', recurring('expense', 350, 5));
  // Multi-turno: data corrigida.
  add(4, 'mt1', ['gastei 55 na farmácia amanhã, pix', 'ops, foi ontem'], 'pergunta ⏎ grava ontem', onceOn('expense', 55, {-1}));
  add(4, 'mt2', ['paguei 130 no conserto do celular no pix', 'foi na terça'], 'grava ⏎ data vira terça ${_dayLabel(_tue)}',
      onceOn('expense', 130, {_tue}));
  add(4, 'mt3', ['recebi 210 de um frete no pix', 'na verdade foi anteontem'], 'grava ⏎ data vira anteontem', onceOn('income', 210, {-2}));
  add(4, 'mt4', ['comprei um vaso de planta de 48 no pix', 'isso foi no dia 28'], 'grava ⏎ data vira ${_dayLabel(dayN(28))}',
      onceOn('expense', 48, {dayN(28)}));

  // ── Eixo 5: estados pendentes × assunto novo (+ "Registro assim?") ──
  // 5a. Fluxo "Registro assim?" (setups calibrados: a frase não diz com certeza que aconteceu).
  bool asked(Ctx c) => c.firstReply.text.contains('Registro assim?');
  Check afterConfirm(Check inner) => (c) {
        final o = inner(c);
        if (o != null) return o;
        if (!asked(c)) return Outcome('INFO', 'setup não pediu confirmação — ${c.summary}');
        return null;
      };
  add(5, 'ra1', ['a padaria tá cobrando 14 no pão de fermentação natural, pix', 'sim'], '"sim" grava 14',
      afterConfirm(one('expense', 14)), settle: false);
  add(5, 'ra2', ['o conserto da janela anda custando 260 no pix', 'pode registrar'], '"pode registrar" grava 260',
      afterConfirm(one('expense', 260)), settle: false);
  add(5, 'ra3', ['compro um ventilador de 180 no débito', 'não'], '"não" descarta; nada pendente', afterConfirm(closedNothing), settle: false);
  add(5, 'ra4', ['a passagem pra campinas vai sair 85 no pix', 'não registra não'], 'descarta', afterConfirm(closedNothing), settle: false);
  add(5, 'ra5', ['esse mês a academia tá 130 no débito', 'foi 135', 'sim'], 'correção de valor ⏎ mostra de novo ⏎ grava 135',
      afterConfirm(one('expense', 135)), settle: false);
  add(5, 'ra6', ['a manicure agora tá 55 no pix', 'no crédito à vista', 'isso'], 'troca a forma ⏎ grava 55 no crédito',
      afterConfirm(one('expense', 55, pay: 'credit_card')), settle: false);
  add(5, 'ra7', ['o frete da geladeira parece que é 90 no pix', 'foi ontem', 'confirmo'], 'muda a data ⏎ grava 90 ontem',
      afterConfirm(one('expense', 90, days: {-1})), settle: false);
  add(5, 'ra8', ['o lanche da escola do menino tá 17 no dinheiro', 'gastei 22 no xerox da apostila no pix'],
      'frase nova: grava 22, não grava 17', afterConfirm(one('expense', 22)), settle: false);
  add(5, 'ra9', ['a farmácia do bairro tá salgada, 93 no débito', 'quanto eu já gastei hoje?'], 'responde; nada gravado',
      afterConfirm(answeredNoSave), settle: false);
  add(5, 'ra10', ['o bolo pro aniversário da vó ficou 120 no pix', 'isso mesmo'], '"isso mesmo" grava 120 (ou nem pergunta)',
      afterConfirm(one('expense', 120)), settle: false);
  add(5, 'ra11', ['a mensalidade da natação anda 150 no pix', 'beleza, pode lançar'], '"beleza, pode lançar" grava 150',
      afterConfirm(one('expense', 150)), settle: false);
  add(5, 'ra12', ['o conserto do portão parece que fica 300 no pix', 'sim, mas foi no dinheiro'], 'grava 300 em dinheiro (ou mostra de novo)',
      (c) {
    final o = one('expense', 300, pay: 'cash')(c);
    if (o == null) return null;
    if (c.added.isEmpty && _confirming(c) && _shown(c).first.paymentMethod == 'cash' && _shown(c).first.amount == 300) return null;
    return o;
  }, settle: false);
  add(5, 'ra13', ['a faxineira tá cobrando 180 a diária, pix', 'esquece isso'], 'cancela', afterConfirm(closedNothing), settle: false);
  add(5, 'ra14', ['o curso de inglês tá 260 por mês no boleto', 'era receita, eu que dou a aula'], 'vira receita (mostra de novo) — nunca despesa',
      (c) {
    if (c.added.any((t) => t.type != TransactionType.income)) return _fail('P0', c, 'gravou como despesa depois de "era receita"');
    if (c.added.isNotEmpty) return null;
    if (_confirming(c) && _shown(c).first.intent == 'income') return null;
    return _fail('P1', c, 'não aplicou "era receita"');
  }, settle: false);
  add(5, 'ra15', ['o pastel da feira tá 13 agora, dinheiro', 'não', 'gastei 13 no pastel no dinheiro'], 'nega ⏎ conta direito ⏎ grava 13',
      one('expense', 13), settle: false);
  add(5, 'ra16', ['a revisão da moto vai sair 340 no pix', 'opa, já paguei sim', ], 'responde com fato: grava 340 (ou pergunta de novo)',
      (c) {
    final o = one('expense', 340)(c);
    if (o == null) return null;
    if (c.added.isEmpty && _confirming(c)) return _fail('P2', c, '"já paguei sim" não foi aceito como confirmação');
    return o;
  }, settle: false);
  // 5b. Rascunho sem valor + resposta legítima.
  final answers = <List<Object>>[
    ['paguei a costureira da barra', 'sessenta e cinco', 'expense', 65.0],
    ['comprei um carregador turbo', '49,90 no pix', 'expense', 49.9],
    ['me pagaram a diária da obra', '150 no pix', 'income', 150.0],
    ['abasteci o carro da patroa', 'deu 210 no débito', 'expense', 210.0],
    ['paguei o pintor do muro', 'R\$ 700 no pix', 'expense', 700.0],
    ['comprei flores pra minha mãe', '55 ontem no pix', 'expense', 55.0, -1],
    ['acertei o fretista', 'trezentos e vinte no pix', 'expense', 320.0],
  ];
  for (var i = 0; i < answers.length; i++) {
    final a = answers[i];
    final day = a.whereType<int>().firstOrNull ?? 0;
    final base = one(a[2] as String, a[3] as double, days: {day});
    add(5, 'ans${i + 1}', [a[0] as String, a[1] as String], 'resposta completa o rascunho: ${a[2]} ${a[3]}', (c) {
      final o = base(c);
      if (o != null) return o;
      if (c.allText.contains('Deixei de lado')) return _fail('P2', c, 'descartou o rascunho em vez de completá-lo');
      return null;
    });
  }
  // 5c. Frase nova com verbo e objeto próprios: lançamento novo com aviso (decisão do usuário).
  add(5, 'new1', ['paguei o despachante', 'tomei um açaí de 18 no pix'], 'despesa 18 (frase nova)', one('expense', 18, notTitle: 'despach'));
  add(5, 'new2', ['comprei uns livros usados', 'recebi 90 de uma rifa no pix'], 'receita 90', one('income', 90, notTitle: 'livro'));
  add(5, 'new3', ['paguei a lavanderia', 'pastel 9 e garapa 6 no dinheiro'], 'lote novo 9+6 substitui o rascunho', many([9, 6]));
  add(5, 'new4', ['comprei uma toalha de banho', 'almocei por 31 no débito'], 'despesa 31 (frase nova)', one('expense', 31, notTitle: 'toalha'));
  // 5d. Frase nova sem valor.
  add(5, 'nov1', ['paguei o encanador do prédio', 'comprei uma mangueira'], 'frase nova sem valor: não funde', notMerged, settle: false);
  add(5, 'nov2', ['recebi do cliente da reforma', 'paguei o motoboy'], 'frase nova sem valor: não funde', notMerged, settle: false);
  // 5e. Perguntas e não-respostas no meio.
  add(5, 'q1', ['comprei um tapete pra sala', 'quanto já foi de gasto nesse mês?'], 'responde; nada gravado', answeredNoSave);
  add(5, 'q2', ['paguei a podóloga', 'o que você consegue fazer por mim?'], 'responde; nada gravado', answeredNoSave);
  add(5, 'ne1', ['paguei o taxista', 'ele era super gente boa'], 'não grava', nothingSaved, settle: false);
  add(5, 'ne2', ['comprei sorvete de massa', 'era umas 3 da tarde'], 'não grava (3 é hora)', nothingSaved, settle: false);
  add(5, 'ne3', ['paguei o conserto da bicicleta', 'levou 4 dias pra ficar pronta'], 'não grava (4 dias)', nothingSaved, settle: false);
  // 5f. Cancelar.
  add(5, 'can1', ['comprei uma panela de pressão', 'esquece, depois eu vejo'], 'descarta', closedNothing, settle: false);
  add(5, 'can2', ['paguei o eletricista do salão', 'deixa quieto por enquanto'], 'descarta', closedNothing, settle: false);
  // 5g. Conversas de 3–6 turnos com mudança de assunto.
  add(5, 'conv1', ['e aí cesar', 'paguei a fisioterapia', 'ah, e caiu 500 do freela no pix', '120 da fisio no pix'],
      'receita 500 + despesa 120', (c) {
    if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
    final a = c.added;
    if (a.any((t) => t.amount == 500 && t.type != TransactionType.income) || a.any((t) => t.amount == 120 && t.type == TransactionType.income)) {
      return _fail('P0', c, 'tipo errado');
    }
    final inc = a.where((t) => t.amount == 500).length, exp = a.where((t) => t.amount == 120).length;
    if (a.length > inc + exp) return _fail('P0', c, 'lançamento extra');
    if (inc == 1 && exp == 1) return null;
    if (_confirming(c)) return _fail('P2', c, 'confirmação desnecessária no meio da conversa');
    return _fail('P1', c, 'faltou lançamento');
  });
  add(5, 'conv2', ['bom dia meu querido', 'gastei 31 de pão e frios no pix', 'quanto gastei hoje?', 'e essa semana?', 'valeu'],
      'um lançamento 31; perguntas respondidas', (c) {
    final o = one('expense', 31)(c);
    if (o != null) return o;
    final r = c.replies[3].route;
    if (r == 'ask' || r == 'saved' || r == 'unknown') return _fail('P1', c, '"e essa semana?" não respondida');
    return null;
  }, settle: false);
  add(5, 'conv3', ['comprei uma cafeteira', 'peraí, deixa eu ver o comprovante', '230 no crédito à vista'], 'despesa 230', one('expense', 230));
  add(5, 'conv4', ['vendi umas coisas no bazar', 'foi bom, vendi bastante', '340 no pix'], 'receita 340', one('income', 340));
  add(5, 'conv5', ['oi', 'a padaria tá cobrando 16 no sonho, pix', 'na verdade eu comprei 2, foi 32', 'sim'], 'corrige ⏎ grava 32',
      one('expense', 32), settle: false);
  add(5, 'conv6', ['paguei o guincho', '280', 'quanto gastei com carro esse mês?', 'apaga esse do guincho', 'sim'],
      'grava 280 ⏎ pergunta ⏎ apaga 280', (c) {
    if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
    if (c.added.isEmpty) return null;
    return _fail('P1', c, 'não apagou o guincho (${c.added.map((t) => t.amount).join(',')})');
  }, settle: false);

  // ── Eixo 6: referência nome × data, edição/exclusão ──
  final edits = <List<Object>>[
    ['o lava jato de sábado foi 40', 'lav', 'a', 40.0],
    ['muda a sorveteria de domingo pra 28', 'sorv', 'a', 28.0],
    ['corrige a drogaria de terça, foi 71', 'drog', 'a', 71.0],
    ['a oficina na verdade saiu 450', 'ofi', 'a', 450.0],
    ['troca a academia pra débito', 'acad', 'p', 'debit_card'],
    ['a pizzaria domingo foi 82', 'pzd', 'a', 82.0],
    ['altera o cinema de hoje pra 64', 'cin', 'a', 64.0],
    ['a ótica do dia ${_domOf(_oticOff)} foi 330', 'otic', 'a', 330.0],
    ['aquele mercado bom preço foi 205', 'merc', 'a', 205.0],
    ['a clínica sorriso foi no crédito', 'clin', 'p', 'credit_card'],
    ['ô cesar, o lava jato custou 38 na real', 'lav', 'a', 38.0],
    ['diminui a oficina pra 400', 'ofi', 'a', 400.0],
    ['a drogaria foi no dinheiro, não no pix', 'drog', 'p', 'cash'],
    ['muda o valor do cinema pra 58', 'cin', 'a', 58.0],
    ['a sorveteria saiu 26, me enganei', 'sorv', 'a', 26.0],
    ['o uber de terça foi 25', 'uber1', 'a', 25.0],
  ];
  for (var i = 0; i < edits.length; i++) {
    final e = edits[i];
    final f = e[2] == 'a' ? (FinancialTransaction t) => t.amount == e[3] : (FinancialTransaction t) => t.paymentMethod == e[3];
    add(6, 'ed${i + 1}', [e[0] as String], '${e[1]} → ${e[3]}', onlyThis(e[1] as String, ok: f), settle: false);
  }
  // Nome fora do título → confirma mostrando o item (decisão do usuário).
  add(6, 'out1', ['a gasolina de segunda foi 190'], 'não muda; mostra Posto Shell', confirmsShowing('Posto Shell', notTitles: ['Oficina']),
      settle: false);
  add(6, 'out2', ['a gasolina de segunda foi 190', 'sim'], 'confirma ⏎ posto → 190', onlyThis('posto', ok: (t) => t.amount == 190), settle: false);
  add(6, 'out3', ['o remédio de terça foi 70'], 'não muda; mostra Drogaria', confirmsShowing('Drogaria'), settle: false);
  add(6, 'out4', ['o remédio de terça foi 70', 'é esse'], 'confirma ⏎ drog → 70', onlyThis('drog', ok: (t) => t.amount == 70), settle: false);
  add(6, 'out5', ['o filme de hoje custou 62'], 'não muda; mostra Cinema', confirmsShowing('Cinema'), settle: false);
  add(6, 'out6', ['a lavagem do carro de sábado foi 37'], 'não muda; mostra Lava Jato', confirmsShowing('Lava Jato'), settle: false);
  add(6, 'out7', ['a gasolina de segunda foi 190', 'não'], 'recusa: nada muda', nothingSaved, settle: false);
  // Exclusão com confirmação.
  final dels = <List<String>>[
    ['apaga a sorveteria de domingo', 'sim', 'sorv'],
    ['exclui o cinema de hoje', 'pode apagar', 'cin'],
    ['tira a pizzaria domingo', 'sim', 'pzd'],
    ['some com a ótica, lancei errado', 'confirmo', 'otic'],
    ['deleta o lava jato de sábado', 'pode', 'lav'],
    ['remove a academia de quarta', 'sim', 'acad'],
  ];
  for (var i = 0; i < dels.length; i++) {
    final d = dels[i];
    add(6, 'del${i + 1}', [d[0], d[1]], 'apaga só ${d[2]} após confirmar', onlyThis(d[2], deleted: true), settle: false);
  }
  // Data errada: não muda e sugere o certo (sem oferecer o distrator do dia).
  final wrong = <List<Object?>>[
    ['o lava jato de terça foi 40', 'Lava Jato', _tue],
    ['a sorveteria de segunda foi 28', 'Sorveteria', _mon],
    ['a oficina de domingo foi 450', 'Oficina', _sun],
    ['a drogaria de sábado foi 71', 'Drogaria', _sat],
    ['a academia de sexta foi 115', 'Academia', _fri],
  ];
  for (var i = 0; i < wrong.length; i++) {
    final w = wrong[i];
    final dis = _titleOn(w[2] as int, except: w[1] as String);
    add(6, 'wr${i + 1}', [w[0] as String], 'não muda; sugere ${w[1]}${dis != null ? ', não $dis' : ''}',
        untouched(w[1] as String, distractor: dis == 'Uber' ? null : dis), settle: false);
  }
  add(6, 'sg1', ['o lava jato de terça foi 40', 'sim'], 'sugestão aceita: lav → 40', onlyThis('lav', ok: (t) => t.amount == 40), settle: false);
  // Duas candidatas (dois Uber).
  add(6, 'mu1', ['o uber foi 25'], 'dois Uber: pergunta qual; nada muda', (c) {
    if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou sem saber qual');
    return null;
  }, settle: false);
  add(6, 'mu2', ['o uber foi 25', 'o de sábado'], 'escolhe uber2 → 25', onlyThis('uber2', ok: (t) => t.amount == 25), settle: false);
  add(6, 'mu3', ['apaga o uber', 'sim'], 'duas candidatas: não apaga sem saber qual', (c) {
    if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'apagou sem saber qual');
    if (c.lastReply.route == 'unknown') return _fail('P2', c, '"sim" à lista caiu na resposta genérica');
    return null;
  }, settle: false);
  // Exclusão de algo que não existe.
  add(6, 'wd1', ['apaga a padaria de ontem', 'sim'], 'nada apagado', noWrongDelete(_titleOn(-1)), settle: false);
  add(6, 'wd2', ['exclui o pet shop', 'sim'], 'nada apagado', noWrongDelete(null), settle: false);
  add(6, 'wd3', ['tira o restaurante de sábado', 'sim'], 'não apaga o Lava Jato', noWrongDelete('Lava Jato'), settle: false);
  // Edição de algo que não existe.
  add(6, 'no1', ['aquele pastel de ontem foi 15'], 'não mexe em registro existente', existingIntact, settle: false);
  add(6, 'no2', ['na verdade o chaveiro foi 50'], 'não mexe em registro existente', existingIntact, settle: false);
  add(6, 'no3', ['passa 40 pra minha prima'], '"passa N pra pessoa" não edita nada', existingIntact, settle: false);
  // "na verdade o X foi N" depois de lançar outra coisa.
  add(6, 'nv1', ['gastei 27 no pão de queijo no pix', 'na real a sorveteria foi 30'], 'sorv → 30; pão de queijo 27 intacto',
      onlyThis('sorv', ok: (t) => t.amount == 30, newAmount: 27), settle: false);
  add(6, 'nv2', ['paguei 12 no estacionamento no pix', 'ops, foram 14'], 'o estacionamento (último) vira 14', (c) {
    if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro antigo');
    if (c.added.length == 1 && c.added.single.amount == 14) return null;
    return _fail('P1', c, 'não corrigiu o último');
  }, settle: false);
  add(6, 'nv3', ['comprei uma pilha de 9 no pix', 'na verdade a drogaria foi 69'], 'drog → 69; pilha 9 intacta',
      onlyThis('drog', ok: (t) => t.amount == 69, newAmount: 9), settle: false);

  // ── Eixo 7: naturalidade da rede de confirmação (50 lançamentos claros) ──
  final clear = <List<Object>>[
    ['almocei num self service, 23,50 no pix', 'expense', 23.5],
    ['estacionamento do shopping 12 no dinheiro', 'expense', 12.0],
    ['compra do mês no atacadão 487,40 no débito', 'expense', 487.4],
    ['uber até o trabalho 16,80 pix', 'expense', 16.8],
    ['comprei pão francês, 9 reais em dinheiro', 'expense', 9.0],
    ['caiu meu salário de 2.870 no pix', 'income', 2870.0],
    ['pedi um lanche no ifood de 46 no crédito à vista', 'expense', 46.0],
    ['drogaria 38,50 débito, vitamina c', 'expense', 38.5],
    ['paguei a conta de luz de setembro, 156 no boleto', 'expense', 156.0],
    ['abasteci 200 de etanol no crédito à vista', 'expense', 200.0],
    ['cafezinho na esquina 6 no pix', 'expense', 6.0],
    ['paguei 45 no barbeiro pix', 'expense', 45.0],
    ['açougue hoje deu 89 no débito', 'expense', 89.0],
    ['paguei 60 na mensalidade da academia no pix', 'expense', 60.0],
    ['almocei com o pessoal do serviço, 34 no pix', 'expense', 34.0],
    ['comprei um chinelo havaianas de 40 no débito', 'expense', 40.0],
    ['recebi 150 de um freela de design no pix', 'income', 150.0],
    ['lanche da tarde 18 no dinheiro', 'expense', 18.0],
    ['paguei o aluguel, 1.300 no pix', 'expense', 1300.0],
    ['feira de domingo 62 dinheiro', 'expense', 62.0, {_sun, 0}],
    ['gastei 15 de sorvete com as crianças, pix', 'expense', 15.0],
    ['paguei 99 da internet da vivo no boleto', 'expense', 99.0],
    ['passagem de metrô 5,30 no débito', 'expense', 5.3],
    ['comprei ração pro gato, 120 no pix', 'expense', 120.0],
    ['pizza de sexta 72 no crédito à vista', 'expense', 72.0, {_fri, 0}],
    ['cortei o cabelo, 30 no dinheiro', 'expense', 30.0],
    ['vendi um fone usado por 80, recebi no pix', 'income', 80.0],
    ['padaria 14,90 débito', 'expense', 14.9],
    ['gastei 250 no supermercado no crédito à vista', 'expense', 250.0],
    ['conta de água 78 paga no boleto', 'expense', 78.0],
    ['ingresso do cinema 44 no pix', 'expense', 44.0],
    ['comprei uma camiseta de 59 na renner no crédito à vista', 'expense', 59.0],
    ['café da manhã na rodoviária, 7 no dinheiro', 'expense', 7.0],
    ['pedágio da imigrantes 22 no débito', 'expense', 22.0],
    ['recebi 400 do aluguel do quarto, caiu no pix', 'income', 400.0],
    ['botijão de gás 115 dinheiro', 'expense', 115.0],
    ['consulta no dentista 180 no pix', 'expense', 180.0],
    ['comprei remédio pra gripe por 27 no débito', 'expense', 27.0],
    ['paguei o boleto do celular, 55', 'expense', 55.0],
    ['lavei o carro, 35 no pix', 'expense', 35.0],
    ['tomei um açaí de 16 no pix agora', 'expense', 16.0],
    ['comprei um livro na amazon por 48 no crédito à vista', 'expense', 48.0],
    ['paguei a faxineira, 180 no pix', 'expense', 180.0],
    ['jantar no japonês 96 no crédito à vista', 'expense', 96.0],
    ['ganhei 50 da minha avó em dinheiro', 'income', 50.0],
    ['gastei 33 na papelaria com material do trabalho, pix', 'expense', 33.0],
    ['mototáxi pra casa 8 em dinheiro', 'expense', 8.0],
    ['pastel com caldo de cana, 17 no dinheiro', 'expense', 17.0],
    ['paguei 70 no veterinário no débito', 'expense', 70.0],
    ['comprei frutas no hortifruti, 26 no pix', 'expense', 26.0],
  ];
  for (var i = 0; i < clear.length; i++) {
    final k = clear[i];
    final days = k.whereType<Set<int>>().firstOrNull ?? {0};
    final base = one(k[1] as String, k[2] as double, days: days);
    add(7, 'nat${i + 1}', [k[0] as String], '${k[1]} ${k[2]} direto, sem pergunta', (c) {
      if (c.added.isEmpty && c.pendingInfo.isNotEmpty && !_confirming(c)) {
        // Qualquer pergunta numa frase clara é desnecessária.
        final miss = _openSlots(c);
        if (c.removed.isEmpty && c.changed.isEmpty) return _fail('P2', c, 'pergunta desnecessária (${miss.join(',')})');
      }
      return base(c);
    }, settle: false);
  }

  return cs;
}

// ─────────────────────────── execução ───────────────────────────

String? _settleAnswer(SimD s) {
  if (s.pendingBatch != null) {
    final open = s.pendingBatch!.where((d) => !d.isComplete).expand((d) => d.missingSlots).toSet();
    if (open.isNotEmpty && open.every((m) => const {'payment_method', 'installments', 'category'}.contains(m))) {
      return open.contains('payment_method') ? 'pix' : (open.contains('category') ? 'outros' : 'à vista');
    }
    return null;
  }
  final a = s.active;
  if (a == null || a.isComplete || a.missingSlots.isEmpty) return null;
  const answers = {'payment_method': 'pix', 'installments': 'à vista', 'recurrence_duration': 'sem prazo', 'category': 'outros', 'due_day': 'dia 10'};
  if (!a.missingSlots.every(answers.containsKey)) return null;
  return answers[a.missingSlots.first];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  test('ACCD lote A r4 — revalidação após 7e', () {
    final cases = buildCases();
    final pass = <int, int>{}, total = <int, int>{}, confirms = <int, int>{};
    final sevCount = <String, int>{};
    print('ACCD_INFO|hoje=${_dm(_today)} weekday=${_today.weekday} casos=${cases.length}');
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
      final sim = SimD(engine, repo);
      final before = {for (final t in repo.transactions) t.id: jsonEncode(t.toJson())};
      final remBefore = repo.reminders.length;
      final turns = <String>[];
      final replies = <R3Reply>[];
      final activeDesc = <String?>[];
      String? crash;
      try {
        for (final t in k.turns) {
          turns.add(t);
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
      if (ctx.everConfirmed) confirms[k.axis] = (confirms[k.axis] ?? 0) + 1;
      var o = crash != null ? Outcome('P1', 'EXCEÇÃO: $crash') : k.check(ctx);
      total[k.axis] = (total[k.axis] ?? 0) + 1;
      if (o != null && o.sev == 'INFO') {
        print('ACCD_NOTE|${k.axis}|${k.id}|${o.got}');
        o = null;
      }
      if (o == null) {
        pass[k.axis] = (pass[k.axis] ?? 0) + 1;
        print('ACCD_OK|${k.axis}|${k.id}|${turns.join(' ⏎ ')}|${ctx.summary}');
      } else {
        sevCount[o.sev] = (sevCount[o.sev] ?? 0) + 1;
        print('ACCD_FAIL|${k.axis}|${k.id}|${o.sev}|${turns.join(' ⏎ ')}|${k.expected}|${o.got}');
      }
    }
    var p = 0, t = 0;
    for (final a in total.keys.toList()..sort()) {
      final ok = pass[a] ?? 0, all = total[a]!;
      p += ok;
      t += all;
      print('ACCD_AXIS|$a|$ok/$all|${(ok * 100 / all).toStringAsFixed(1)}%|confirmações=${confirms[a] ?? 0}');
    }
    print('ACCD_TOTAL|$p/$t|${(p * 100 / t).toStringAsFixed(1)}%|sev=$sevCount');
  });
}
