// Portão de qualidade do Item 2, lote A (PLANO_CESAR.md) — REVALIDAÇÃO FINAL
// da etapa 5 depois das correções 7a, 7b, 7c (EntrySafetyGate) e
// 7d (PendingReplyCheck).
//
// Frases INÉDITAS: cada turno com 4+ tokens tem Jaccard de tokens < 0,6
// contra todos os literais de `test/**/*.dart` (inclusive cesar_gate_a_7c/7d
// e as baterias _qa) e os trechos de `docs/qa/*.md` — conferido por script
// antes de rodar (respostas curtas como "sim", "pix", "45" ficam de fora).
// Estilos: voz sem pontuação e com números por extenso, regionalismos, gírias
// de jovens e de idosos, WhatsApp abreviado, erros de digitação, frases longas
// com ruído, ordem trocada, conversas de 3–5 turnos com mudança de assunto.
//
// Só imprime (nunca falha a suíte):
//   ACCC_FAIL|eixo|id|sev|entrada|esperado|obtido
//   ACCC_OK|eixo|id|entrada|obtido
//   ACCC_AXIS|eixo|passou/total|pct
//   ACCC_TOTAL|passou/total|pct|sev
//
// Rodar:
//   flutter test test/_qa/acceptance_lote_a_r3_probe_test.dart 2>&1 | grep -E "ACCC_"
//
// Datas sempre relativas a DateTime.now() (sem nome de mês fixo). Cada caso
// roda num repositório limpo com o `SimC` (espelho do `_sendMessage` ATUAL —
// o `SimB` do chaos_lote_a_r2 mais o passo da 7c que manda um lote novo
// substituir o rascunho pendente, com o aviso de descarte). `hypothesisReply`
// é chamado como no chat: antes do merge do lote pendente e dentro do
// `handleQuestion`. Quando o César só pergunta forma de pagamento / parcelas /
// prazo / categoria (regra de produto, fora do objeto do eixo) a sonda
// responde como o usuário ("pix", "à vista", "sem prazo", "outros") — esses
// turnos aparecem entre colchetes.
//
// Pergunta desnecessária ("entrou ou saiu?" em frase óbvia, data numa frase
// sem dúvida de data, "qual dos valores?" com um valor só) conta como falha P2.
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

class SimC {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  FinancialTransactionDraft? active;
  FinancialTransactionDraft? last;
  List<String> lastIds = const [];
  List<FinancialTransactionDraft>? pendingBatch;
  static int _goalSeq = 0;

  SimC(this.engine, this.repo) : assistant = CesarAssistant(repository: repo, engine: engine);

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
      repo.addGoal(FinancialGoal(id: 'goal-c-${++_goalSeq}', title: goalCreation.title, targetAmount: goalCreation.targetAmount, targetDate: goalCreation.targetDate));
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

    // 7c (CHAOS-B-007): um lote novo digitado com rascunho pendente o substitui.
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
          id: 'rem-c-${repo.reminders.length + 1}-${DateTime.now().microsecondsSinceEpoch}',
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
  final SimC sim;
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

  String get pendingInfo {
    final a = sim.active;
    if (sim.pendingBatch != null) return 'lote pendente(${sim.pendingBatch!.map((d) => '${d.amount}/${d.missingSlots}').join(';')})';
    if (a != null && !a.isComplete) return 'rascunho pendente ${a.intent} ${a.amount} "${a.description}" missing=${a.missingSlots}';
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
DateTime _lastMonth = DateTime(_today.year, _today.month - 1, 1);

bool _sameDay(DateTime a, int offset) {
  final e = DateTime(_today.year, _today.month, _today.day + offset);
  return a.year == e.year && a.month == e.month && a.day == e.day;
}

String _dayLabel(int offset) => _dm(_today.add(Duration(days: offset)));

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

bool _askedType(Ctx c) {
  if (_openSlots(c).contains('type')) return true;
  final t = _fold(c.lastReply.text);
  return t.contains('entrou') && t.contains('saiu');
}

bool _generic(Ctx c) => c.lastReply.route == 'unknown' && c.lastReply.text.contains('gasto ou uma receita');

bool _askedDate(Ctx c) => _openSlots(c).contains('date');
bool _askedSplit(Ctx c) => _openSlots(c).contains('split') || _openSlots(c).contains('amount');

/// Exatamente um lançamento novo, do tipo/valor dados; nada editado/apagado.
/// [days]: datas aceitas (default: hoje). Perguntar tipo/data/valor só é aceito
/// quando a flag correspondente permite; senão é pergunta desnecessária (P2).
Check one(String type, double amount,
        {Set<String>? types,
        Set<int>? days,
        bool anyDay = false,
        bool askTypeOk = false,
        bool askDateOk = false,
        bool askSplitOk = false,
        String? pay,
        String? notTitle}) =>
    (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
      final a = c.added;
      if (a.isEmpty) {
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
      final okTypes = types ?? {type};
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

Check income(double v, {bool askOk = false, Set<int>? days}) => one('income', v, askTypeOk: askOk, days: days);
Check expense(double v, {bool askOk = false, Set<int>? days, Set<String>? types}) => one('expense', v, askTypeOk: askOk, days: days, types: types);

/// Direção ambígua: tem de perguntar "entrou ou saiu?"; gravar qualquer tipo é P0.
Outcome? askType(Ctx c) {
  if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
  if (c.added.isNotEmpty) return _fail('P0', c, 'assumiu a direção (${c.added.first.type.name}) sem perguntar');
  if (_askedType(c)) return null;
  if (_generic(c)) return _fail('P2', c, 'pergunta genérica (gasto ou receita?) e perde o valor');
  return _fail('P1', c, 'não perguntou "entrou ou saiu?"');
}

/// Vários lançamentos; [types]: tipos aceitos por valor (na ordem de [amounts]).
/// [days]: data por valor (opcional).
Check many(List<double> amounts, {List<Set<String>>? types, List<int>? days}) => (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
      final a = c.added;
      if (a.isEmpty) {
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
  if (c.pendingInfo.isEmpty) return _fail('P2', c, 'não ficou perguntando');
  return null;
}

/// Hipótese / intenção / não-evento: nada gravado nem alterado, e não vira
/// rascunho de lançamento (a sonda responde aos slots; se gravar depois, é P0).
Outcome? noEntry(Ctx c) {
  if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'gravou/alterou dados');
  if (c.pendingInfo.isNotEmpty) return _fail('P1', c, 'tratou como lançamento (rascunho pendente)');
  if (_generic(c)) return _fail('P2', c, 'não entendeu a hipótese (resposta genérica)');
  if (c.lastReply.route.startsWith('report')) return _fail('P2', c, 'respondeu com relatório sem sentido');
  return null;
}

/// Data futura: não grava lançamento; pergunta a data (lembrete futuro também serve).
Outcome? futureAsks(Ctx c) {
  if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
  if (c.added.isNotEmpty) return _fail('P0', c, 'gravou com data ${_dm(c.added.first.date)} sem perguntar');
  if (_askedDate(c)) return null;
  if (c.repo.reminders.length > c.remindersBefore) return null;
  return _fail('P1', c, 'não perguntou a data');
}

Check recurring(String type, double amount, int due) => (c) {
      final a = c.added;
      if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
      if (a.isEmpty) {
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

Check onceOn(String type, double amount, Set<int> days, {bool askDateOk = false, bool askTypeOk = false}) => (c) {
      final base = one(type, amount, days: days, askDateOk: askDateOk, askTypeOk: askTypeOk)(c);
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

/// Dia do mês de um registro N dias atrás (para "a clínica do dia X").
int _domOf(int offset) => _today.add(Duration(days: offset)).day;
final int _clinOff = -16;
final int _barb2Off = _sat - 7;

List<FinancialTransaction> _seed6() => [
      _tx('quit', 'Quitanda', 41, _sat, 'supermarket'),
      _tx('acou', 'Açougue', 88, _thu, 'supermarket'),
      _tx('bor', 'Borracharia', 60, _fri, 'transport'),
      _tx('sap', 'Sapataria', 75, _mon, 'expense_other'),
      _tx('hamb', 'Hamburgueria', 52, _sun, 'leisure'),
      _tx('pap', 'Papelaria', 19, _tue, 'education'),
      _tx('flor', 'Floricultura', 90, -1, 'expense_other'),
      _tx('pet', 'Pet Shop', 110, 0, 'expense_other'),
      _tx('clin', 'Clínica Vida', 300, _clinOff, 'health'),
      _tx('barb1', 'Barbearia', 45, _sat, 'expense_other'),
      _tx('barb2', 'Barbearia', 45, _barb2Off, 'expense_other'),
      _tx('padsab', 'Padaria Sábado', 24, _tue, 'supermarket'),
      _tx('merc', 'Mercado Terça', 130, _fri, 'supermarket'),
      _tx('posto', 'Posto Ipiranga', 200, _mon, 'transport'),
    ];

Check untouched(String title, {String? distractor}) => (c) {
      if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou dados sem confirmação');
      if (c.pendingInfo.isNotEmpty) return _fail('P1', c, 'virou lançamento novo pendente');
      if (distractor != null && c.allText.contains(distractor)) return _fail('P2', c, 'ofereceu o distrator $distractor');
      if (!c.allText.contains(title)) return _fail('P2', c, 'não sugeriu $title');
      return null;
    };

Check onlyThis(String id, {bool deleted = false, bool Function(FinancialTransaction t)? ok, bool askOk = false, double? newAmount}) => (c) {
      final adds = c.added;
      if (newAmount == null && adds.isNotEmpty) return _fail('P0', c, 'criou lançamento novo');
      if (newAmount != null && (adds.length != 1 || (adds.single.amount - newAmount).abs() > 0.005)) {
        return _fail('P0', c, 'lançamento novo deveria ser só $newAmount');
      }
      if (askOk && c.removed.isEmpty && c.changed.isEmpty && const {'ask_correction_or_new', 'confirm', 'choose'}.contains(c.lastReply.route)) return null;
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

Outcome? existingIntact(Ctx c) {
  if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
  return null;
}

Check noWrongDelete(String distractor) => (c) {
      if (c.removed.isNotEmpty || c.changed.isNotEmpty || c.added.isNotEmpty) return _fail('P0', c, 'mudou dados');
      if (c.firstReply.route == 'confirm_delete') return _fail('P0', c, 'pediu confirmação para apagar outro registro');
      if (c.firstReply.text.contains(distractor)) return _fail('P2', c, 'citou o distrator $distractor');
      return null;
    };

// ─────────────────────────── casos ───────────────────────────

List<Case> buildCases() {
  final cs = <Case>[];
  void add(int axis, String id, List<String> turns, String exp, Check chk, {bool settle = true}) =>
      cs.add(Case(axis, id, turns, exp, chk, settle: settle));

  // ── Eixo 1: direção do dinheiro ──
  // Direção óbvia: perguntar "entrou ou saiu?" é P2.
  add(1, 'in1', ['recebi do inquilino setecentos e cinquenta referente ao quarto no pix'], 'receita 750', income(750));
  add(1, 'in2', ['eita caiu na conta 2350 do salario da prefeitura'], 'receita 2350', income(2350));
  add(1, 'in3', ['a cliente da unha me pagou 65 no pix'], 'receita 65', income(65));
  add(1, 'in4', ['ganhei 300 no amigo secreto da firma em especie'], 'receita 300', income(300));
  add(1, 'in5', ['o banco me devolveu 27 de tarifa cobrada errada'], 'receita 27 (estorno)', income(27));
  add(1, 'in6', ['entrou um pix de 410 da venda do berço'], 'receita 410', income(410));
  add(1, 'in7', ['vendi a bike velha por 520 pro vizinho, ele mandou no pix'], 'receita 520', income(520));
  add(1, 'in8', ['meu pai me deu 200 de presente de niver'], 'receita 200', income(200));
  add(1, 'in9', ['a seguradora indenizou 3800 do carro batido'], 'receita 3800', income(3800));
  add(1, 'in10', ['chegou o cashback de 18 do cartão'], 'receita 18', income(18));
  add(1, 'in11', ['veio 95 de comissão da revenda de cosmeticos'], 'receita 95', income(95));
  add(1, 'in12', ['meu ex depositou a pensão das crianças 900'], 'receita 900', income(900));
  add(1, 'in13', ['minha vó me presenteou com cem conto, que benção'], 'receita 100', income(100));
  add(1, 'in14', ['me mandaram 85 de volta do bolão q nao rolou'], 'receita 85', income(85));
  add(1, 'in15', ['oxente a patroa me adiantou 350 da quinzena'], 'receita 350', income(350));
  // Direção dita "ao contrário" (quem recebe/paga é o outro): tipo certo ou pergunta.
  add(1, 'rev1', ['meu irmão pagou 70 pra mim do ingresso'], 'receita 70 ou pergunta', income(70, askOk: true));
  add(1, 'rev2', ['o motoboy recebeu 15 de mim pela entrega'], 'despesa 15 ou pergunta (nunca receita)', expense(15, askOk: true));
  add(1, 'rev3', ['a escola recebeu de mim 600 da matricula'], 'despesa 600 ou pergunta', expense(600, askOk: true));
  add(1, 'rev4', ['quem bancou o jantar de 160 fui eu'], 'despesa 160 ou pergunta', expense(160, askOk: true));
  add(1, 'rev5', ['meu cunhado acertou comigo os 180 da bicicleta'], 'receita 180 ou pergunta', income(180, askOk: true));
  add(1, 'rev6', ['a loja de roupa ficou com 210 meu'], 'despesa 210 ou pergunta', expense(210, askOk: true));
  // Despesa óbvia.
  add(1, 'out1', ['paguei 230 de iptu em cota unica no boleto'], 'despesa 230', expense(230));
  add(1, 'out2', ['gastei 47 de remedio pra pressão da minha vó no pix'], 'despesa 47', expense(47));
  add(1, 'out3', ['o encanador cobrou 180 e eu paguei na hora no pix'], 'despesa 180', expense(180));
  add(1, 'out4', ['dei 50 de gorjeta pro garçom no dinheiro'], 'despesa 50', expense(50));
  add(1, 'out5', ['desembolsei 2700 na entrada da moto'], 'despesa 2700', expense(2700));
  add(1, 'out6', ['botei 20 de credito no celular pré pago'], 'despesa 20', expense(20));
  add(1, 'out7', ['transferi 300 pro meu irmão pagar a faculdade'], 'despesa/transferência 300', expense(300, types: {'expense', 'transfer'}));
  add(1, 'out8', ['deixei 150 na oficina do zé pelo alinhamento'], 'despesa 150 (ou pergunta)', expense(150, askOk: true));
  add(1, 'out9', ['saiu 34,90 da conta pela assinatura do deezer'], 'despesa 34,90', expense(34.9));
  // Armadilhas: palavra de entrada com dinheiro saindo.
  add(1, 'trap1', ['caí no golpe do pix e perdi 350'], 'despesa 350 ou pergunta (nunca receita)', expense(350, askOk: true));
  add(1, 'trap2', ['recebi a conta de agua de 98 e ja paguei no pix'], 'despesa 98 (conta recebida ≠ dinheiro recebido)', expense(98, askOk: true));
  add(1, 'trap3', ['recebi uma multa de 195 do radar'], 'despesa 195 ou pergunta (nunca receita)', expense(195, askOk: true));
  add(1, 'trap4', ['ganhei 40 de desconto no tenis e paguei 260 no débito'], 'despesa 260 (desconto não é receita)', (c) {
    final a = c.sim.active;
    if (c.added.isEmpty && a != null && !a.isComplete && a.amount == 40) {
      return _fail('P1', c, 'pergunta "entrou ou saiu?" sobre o desconto (40), não sobre o valor pago');
    }
    return expense(260, askOk: true)(c);
  });
  add(1, 'trap5', ['chegou o boleto do condominio 540 paguei agora no pix'], 'despesa 540', expense(540, askOk: true));
  add(1, 'trap6', ['tive um prejuizo de 120 com mercadoria estragada'], 'despesa 120 ou pergunta', expense(120, askOk: true));
  // Ambíguo: tem de perguntar.
  add(1, 'amb1', ['rolou um acerto de 250 com o pedreiro'], 'pergunta "entrou ou saiu?"', askType, settle: false);
  add(1, 'amb2', ['pix 130 joana'], 'pergunta "entrou ou saiu?"', (c) {
    final o = askType(c);
    if (o != null && o.sev == 'P1' && c.added.isEmpty && _fold(c.lastReply.text).contains('gasto')) {
      return _fail('P2', c, 'assumiu saída (avisa "gasto" na pergunta) em vez de perguntar a direção');
    }
    return o;
  }, settle: false);
  add(1, 'amb3', ['acertamos 400 do carro eu e o lucas'], 'pergunta "entrou ou saiu?"', askType, settle: false);
  add(1, 'amb4', ['tretei 50 com o vendedor da feira'], 'despesa 50 ou pergunta', expense(50, askOk: true));
  add(1, 'amb5', ['fiz um corre de 90 hj'], 'receita 90 ou pergunta (nunca despesa)', income(90, askOk: true));
  add(1, 'amb6', ['75 com o dentista'], 'despesa 75 ou pergunta (nunca receita)', expense(75, askOk: true));
  add(1, 'amb7', ['negociei 600 com o comprador do notebook'], 'receita 600 ou pergunta (nunca despesa)', income(600, askOk: true));
  add(1, 'amb8', ['mexemo 200 la com o tio do bar'], 'pergunta "entrou ou saiu?"', askType, settle: false);

  // ── Eixo 2: multi-lançamento e números que não são valor ──
  add(2, 'm1', ['dois cafés 9 e um pão de queijo 6 no débito'], '2 despesas 9+6', many([9, 6]));
  add(2, 'm2', ['gasolina cento e vinte e lava jato trinta no pix'], '2 despesas 120+30', many([120, 30]));
  add(2, 'm3', ['xerox 4 caneta 3 caderno 22 no dinheiro'], '3 despesas 4+3+22', many([4, 3, 22]));
  add(2, 'm4', ['oi cesar paguei 60 na pizzaria e 14 no refri da conveniencia, pix'], '2 despesas 60+14', many([60, 14]));
  add(2, 'm5', ['dentista 200 e remedio 37 ambos no debito'], '2 despesas 200+37', many([200, 37]));
  add(2, 'm6', ['ingresso 80 pipoca 25 estacionamento 18 tudo credito a vista'], '3 despesas', many([80, 25, 18]));
  add(2, 'm7', ['mandei 50 pra minha irmã e recebi 120 do meu tio no pix'], 'despesa/transf 50 + receita 120',
      many([50, 120], types: [{'expense', 'transfer'}, {'income'}]));
  add(2, 'm8', ['açougue 54,90 e padaria 11,40 no pix'], '2 despesas 54,90+11,40', many([54.9, 11.4]));
  add(2, 'm9', ['paguei a luz 132 e a agua 76 no boleto'], '2 despesas 132+76', many([132, 76]));
  add(2, 'm10', ['ontem uber 22 e hoje uber 19 no pix'], '22 ontem + 19 hoje', many([22, 19], days: [-1, 0]));
  add(2, 'm11', ['recebi 800 da diaria e gastei 45 no almoço no pix'], 'receita 800 + despesa 45',
      many([800, 45], types: [{'income'}, {'expense'}]));
  add(2, 'm12', ['manicure 35, sobrancelha 25, no pix'], '2 despesas 35+25', many([35, 25]));
  add(2, 'm13', ['coxinha 7 suco 9 no dinheiro'], '2 despesas 7+9', many([7, 9]));
  add(2, 'm14', ['torrei quarenta reais no sacolão e vinte e cinco na drogaria tudo pix'], '2 despesas 40+25 (voz)', many([40, 25]));
  add(2, 'm15', ['recebi mil do freela e paguei duzentos de aluguel da vaga no pix'], 'receita 1000 + despesa 200 (voz)',
      many([1000, 200], types: [{'income'}, {'expense'}]));
  add(2, 'm16', ['almoço 28 no pix e janta 35 no credito a vista'], '2 despesas 28+35', many([28, 35]));
  // Números que não são valor.
  add(2, 's1', ['paguei 70 no corte de cabelo no salão da rua 9 no pix'], 'UM lançamento de 70', expense(70));
  add(2, 's2', ['comprei 4 pneus aro 14 por 1200 no credito em 6x'], 'UM lançamento de 1200', expense(1200));
  add(2, 's3', ['botei 100 de gasolina, o carro tava com 1/4 do tanque, pix'], 'UM lançamento de 100', expense(100));
  add(2, 's4', ['paguei 42 na pizza do apê 1203 no pix'], 'UM lançamento de 42', expense(42));
  add(2, 's5', ['comprei uma tv de 50 polegadas por 2800 no credito em 10x'], 'UM lançamento de 2800', expense(2800));
  add(2, 's6', ['gastei 65 na festa de 15 anos da sobrinha no pix'], 'UM lançamento de 65', expense(65));
  add(2, 's7', ['comprei 2 kg de carne por 89 no débito'], 'UM lançamento de 89', expense(89));
  add(2, 's8', ['paguei 150 da consulta com o dr paulo crm 45678 no pix'], 'UM lançamento de 150', expense(150));
  add(2, 's9', ['pedi 3 marmitas por 54 no pix'], 'UM lançamento de 54 (total)', expense(54));
  add(2, 's10', ['comprei um tenis tamanho 42 por 199 no pix'], 'UM lançamento de 199', expense(199));
  add(2, 's11', ['gastei 25 no lava rapido do km 32 da rodovia no pix'], 'UM lançamento de 25', expense(25));
  add(2, 's12', ['paguei 12 na cerveja de 600ml no dinheiro'], 'UM lançamento de 12', expense(12));
  add(2, 's13', ['comprei a passagem do voo 3345 por 780 no credito a vista'], 'UM lançamento de 780', expense(780));
  add(2, 's14', ['paguei 90 no pet shop pro banho da cachorra de 7 anos no pix'], 'UM lançamento de 90', expense(90));
  add(2, 's15', ['paguei duzentos e trinta reais de conta de luz no boleto'], 'UM lançamento de 230 (voz)', expense(230));
  add(2, 's16', ['gastei 1.299,90 numa geladeira no credito em 12x'], 'UM lançamento de 1299,90', expense(1299.9));
  add(2, 's17', ['comprei um chip com ddd 21 por 15 no pix'], 'UM lançamento de 15', expense(15));
  add(2, 's18', ['paguei 58 de internet do plano de 300 mega no boleto'], 'UM lançamento de 58', expense(58));
  add(2, 's19', ['deu 3,50 o pão de sal no dinheiro'], 'UM lançamento de 3,50', expense(3.5));
  add(2, 's20', ['comprei 6 latinhas a 4 cada no pix'], 'UM lançamento de 24 (6 × 4)', expense(24));
  add(2, 's21', ['comprei 1 pizza grande de 65 no pix'], 'UM lançamento de 65', expense(65));
  add(2, 's22', ['gastei 300 em 5 camisetas no credito a vista'], 'UM lançamento de 300', expense(300));
  add(2, 's23', ['paguei o rodizio de 2 horas no parque, deu 33 no pix'], 'UM lançamento de 33', expense(33));
  add(2, 's24', ['bah, paguei 48 na erva mate de 1 quilo no pix'], 'UM lançamento de 48', expense(48));
  add(2, 's25', ['comprei uma furadeira de 220 volts por 340 no pix'], 'UM lançamento de 340', expense(340));
  // Valor incerto.
  add(2, 'r1', ['acho que gastei uns 50 ou 60 na feira no pix'], 'dois valores: pergunta, não grava', noRecordAsks, settle: false);
  add(2, 'r2', ['paguei entre 70 e 80 no frete nao lembro direito, pix'], 'faixa: pergunta, não grava', noRecordAsks, settle: false);
  add(2, 'r3', ['o mercado deu 130 e pouco no débito'], '130 (ou pergunta)', one('expense', 130, askSplitOk: true));

  // ── Eixo 3: hipóteses / intenção × fatos ──
  const hyp = [
    'se eu trocar de celular agora por um de 2200 fico apertado?',
    'imagina eu gastando 600 numa bike, cabe?',
    'e se o conserto do carro der 1500?',
    'supondo que eu receba 3000 de decimo terceiro, quanto fica meu saldo',
    'caso eu feche o freela de 1200 consigo quitar o cartão?',
    'na hipotese de eu pagar 450 de academia anual, compensa?',
    'se rolar uma viagem de 1800 no fim do ano da?',
    'tava pensando em gastar 120 num perfume',
    'pretendo comprar uma geladeira de 3200 mês que vem',
    'vou gastar uns 400 no mercado amanhã',
    'to planejando pagar 900 de ipva em 3 vezes',
    'será que dá pra eu gastar 80 no cinema hoje?',
    'se a luz vier 300 esse mes eu to lascado',
    'quanto sobraria se eu pagasse 700 de aluguel',
    'pensando aqui: um notebook de 4500 em 10x pesa quanto por mes?',
    'seria loucura gastar 500 num show?',
    'talvez eu compre um tenis de 280 sabado',
    'vou receber 1500 do acerto semana que vem',
    'se o cliente pagar os 2000 hoje eu quito o cartão',
    'to na duvida se compro a air fryer de 380 ou nao',
    'minha ideia é torrar 250 no rodízio de aniversário',
    'daria pra gastar 160 num jantar sem me enrolar?',
  ];
  for (var i = 0; i < hyp.length; i++) {
    add(3, 'hyp${i + 1}', [hyp[i]], 'não grava; responde a hipótese/intenção', noEntry);
  }
  // Não-eventos.
  const nonEvents = [
    'quase comprei um videogame de 2500 mas desisti',
    'ainda nao paguei os 320 da escola',
    'desisti de pagar 70 na academia nova',
    'ia gastar 90 no barzinho mas fiquei em casa',
    'nem cheguei a pagar os 45 do estacionamento, o cara liberou',
    'era pra eu receber 300 hoje mas o cliente furou',
  ];
  for (var i = 0; i < nonEvents.length; i++) {
    add(3, 'non${i + 1}', [nonEvents[i]], 'não aconteceu: não grava', noEntry);
  }
  // Fatos com "se/caso/quero/vou/pensei": gravam.
  add(3, 'f1', ['se liga, gastei 72 na farmácia agora no pix'], 'despesa 72', expense(72));
  add(3, 'f2', ['eu ia esperar mas acabei comprando o fone de 250 no pix'], 'despesa 250', expense(250));
  add(3, 'f3', ['quis economizar mas paguei 95 no salão no débito'], 'despesa 95', expense(95));
  add(3, 'f4', ['pensei que ia sair mais caro, mas o conserto ficou 160 no pix'], 'despesa 160', expense(160));
  add(3, 'f5', ['nao sei se vc lembra, mas recebi 600 do aluguel do ponto no pix'], 'receita 600', income(600));
  add(3, 'f6', ['vou te contar: torrei 230 na balada no credito a vista'], 'despesa 230', expense(230));
  add(3, 'f7', ['quero registrar que paguei 48 de gás no dinheiro'], 'despesa 48', expense(48));
  add(3, 'f8', ['vou anotar aqui, entrou 350 de comissão no pix'], 'receita 350', income(350));
  add(3, 'f9', ['caso vc nao saiba, a academia me cobrou 110 no debito'], 'despesa 110', expense(110));
  add(3, 'f10', ['se nao me falha a memoria gastei 66 no açougue no pix'], 'despesa 66', expense(66));
  add(3, 'f11', ['planejei gastar 100 mas gastei 140 na feira no pix'], 'despesa 140 (100 era plano) ou pergunta',
      one('expense', 140, askSplitOk: true));
  add(3, 'f12', ['eu tinha prometido que nao ia gastar, mas gastei 55 no ifood no pix'], 'despesa 55', expense(55));
  add(3, 'f13', ['a ideia era só olhar, acabei levando uma blusa de 89 no credito a vista'], 'despesa 89', expense(89));
  add(3, 'f14', ['meu plano era pagar a vista e paguei 600 no pix'], 'despesa 600', expense(600));
  add(3, 'f15', ['como combinado, recebi 450 do conserto no pix'], 'receita 450', income(450));
  add(3, 'f16', ['se tu quer saber, o almoço de hoje saiu 42 no débito'], 'despesa 42 hoje', expense(42));
  add(3, 'f17', ['vou falar logo: paguei 1100 do aluguel no boleto'], 'despesa 1100', expense(1100));
  add(3, 'f18', ['pretendia guardar, mas gastei 75 no sapato no pix'], 'despesa 75', expense(75));

  // ── Eixo 4: datas ao lançar e recorrência ──
  add(4, 'd1', ['ontem de noitinha paguei 38 no podrão no pix'], 'despesa 38 ontem', onceOn('expense', 38, {-1}));
  add(4, 'd2', ['anteontem recebi 280 de uma diaria no pix'], 'receita 280 anteontem', onceOn('income', 280, {-2}));
  add(4, 'd3', ['trasantontem gastei 60 na feira no dinheiro'], 'despesa 60 há 3 dias (ou pergunta)', onceOn('expense', 60, {-3}, askDateOk: true));
  add(4, 'd4', ['segunda passada paguei 95 na consulta do pé no pix'], 'despesa 95 segunda (${_dayLabel(_mon)}/${_dayLabel(_mon - 7)}) ou pergunta',
      onceOn('expense', 95, {_mon, _mon - 7}, askDateOk: true));
  add(4, 'd5', ['na terça gastei 44 de uber no pix'], 'despesa 44 terça ${_dayLabel(_tue)}', onceOn('expense', 44, {_tue}));
  add(4, 'd6', ['quarta feira recebi 150 do bico no pix'], 'receita 150 quarta ${_dayLabel(_wed)}', onceOn('income', 150, {_wed}));
  add(4, 'd7', ['faz 4 dias gastei 30 no chaveiro no dinheiro'], 'despesa 30 há 4 dias', onceOn('expense', 30, {-4}));
  add(4, 'd8', ['há duas semanas paguei 180 no eletricista no pix'], 'despesa 180 há 14 dias (ou pergunta)', onceOn('expense', 180, {-14}, askDateOk: true));
  add(4, 'd9', ['no dia 27 comprei um tapete de 140 no pix'], 'despesa 140 em ${_dayLabel(dayN(27))}', onceOn('expense', 140, {dayN(27)}));
  add(4, 'd10', ['dia primeiro paguei 90 de net no boleto'], 'despesa 90 em ${_dayLabel(dayN(1))}', onceOn('expense', 90, {dayN(1)}));
  add(4, 'd11', ['paguei 75 no veterinario dia 29 no pix'], 'despesa 75 em ${_dayLabel(dayN(29))}', onceOn('expense', 75, {dayN(29)}));
  add(4, 'd12', ['dia 20 do mês passado recebi 500 de comissão no pix'], 'receita 500 em ${_dayLabel(lastMonthDay(20))}',
      onceOn('income', 500, {lastMonthDay(20)}));
  add(4, 'd13', ['mês passado no dia 12 gastei 230 no dentista no pix'], 'despesa 230 em ${_dayLabel(lastMonthDay(12))}',
      onceOn('expense', 230, {lastMonthDay(12)}));
  add(4, 'd14', ['hoje de manhã paguei 16 no café da padaria no pix'], 'despesa 16 hoje', onceOn('expense', 16, {0}));
  add(4, 'd15', ['agorinha mesmo comprei revista por 23 na banca, paguei no pix'], 'despesa 23 hoje', onceOn('expense', 23, {0}));
  add(4, 'd16', ['ontem anoite, paguei 52 de gasolina pix'], 'despesa 52 ontem', onceOn('expense', 52, {-1}));
  add(4, 'd17', ['ontem eu paguei sessenta reais de ração pro cachorro no pix'], 'despesa 60 ontem (voz)', onceOn('expense', 60, {-1}));
  add(4, 'd18', ['semana retrasada gastei 200 no mecanico no pix'], 'despesa 200 entre -14 e -8 (ou pergunta)',
      onceOn('expense', 200, {for (var i = -14; i <= -7; i++) i}, askDateOk: true));
  add(4, 'd19', ['domingo recebi 70 de uma rifa no pix'], 'receita 70 domingo ${_dayLabel(_sun)}', onceOn('income', 70, {_sun}));
  add(4, 'd20', ['sexta passada paguei 85 no bar no pix'], 'despesa 85 sexta (${_dayLabel(_fri)}/${_dayLabel(_fri - 7)}) ou pergunta',
      onceOn('expense', 85, {_fri, _fri - 7}, askDateOk: true));
  add(4, 'd21', ['tava no onibus voltando do serviço ontem quando paguei 4,90 de passagem no cartão de débito'], 'despesa 4,90 ontem',
      onceOn('expense', 4.9, {-1}));
  add(4, 'd22', ['hoje lembrei que paguei 110 na farmácia anteontem no pix'], 'despesa 110 anteontem ("hoje" é quando lembrou)',
      onceOn('expense', 110, {-2}, askDateOk: true));
  add(4, 'd23', ['só hoje vi que caiu 300 de reembolso ontem no pix'], 'receita 300 ontem', onceOn('income', 300, {-1}, askDateOk: true));
  add(4, 'd24', ['paguei 58 no mercado 1º de maio no pix'], 'despesa 58 hoje (nome da loja) ou pergunta', onceOn('expense', 58, {0}, askDateOk: true));
  add(4, 'd25', ['paguei 210 na loja da avenida 9 de julho no pix'], 'despesa 210 hoje (endereço) ou pergunta', onceOn('expense', 210, {0}, askDateOk: true));
  add(4, 'd26', ['em ${_dayLabel(-3)} paguei 37 de farmácia no pix'], 'despesa 37 em ${_dayLabel(-3)}', onceOn('expense', 37, {-3}));
  add(4, 'd27', ['dia vinte e oito do mês passado paguei cem reais de luz'], 'despesa 100 em ${_dayLabel(lastMonthDay(28))} (voz)',
      onceOn('expense', 100, {lastMonthDay(28)}));
  add(4, 'd28', ['quinta passada gastei 77 no salão no pix'], 'despesa 77 quinta (${_dayLabel(_thu)}) ou pergunta',
      onceOn('expense', 77, {_thu, _thu - 7}, askDateOk: true));
  add(4, 'd29', ['recebi 900 de bonus no dia 5 no pix'], 'receita 900 em ${_dayLabel(dayN(5))}', onceOn('income', 900, {dayN(5)}));
  add(4, 'd30', ['paguei 230 do ingles dia 18 no pix'], 'despesa única 230 em ${_dayLabel(dayN(18))}', onceOn('expense', 230, {dayN(18)}));
  // Futuro: pergunta.
  add(4, 'fut1', ['paguei 70 de unha na terça que vem no pix'], 'data futura: pergunta', futureAsks);
  add(4, 'fut2', ['gastei 90 no mercado daqui a dois dias no pix'], 'data futura: pergunta', futureAsks);
  add(4, 'fut3', ['recebi 400 do bico dia 15 do mes que vem no pix'], 'data futura: pergunta', futureAsks);
  add(4, 'fut4', ['paguei 50 de gás amanha no pix'], 'data futura: pergunta', futureAsks);
  add(4, 'fut5', ['no proximo sabado gastei 100 no rodizio no pix'], 'data futura: pergunta', futureAsks);
  add(4, 'wknd', ['gastei 95 no fim de semana com cerveja no pix'], 'sábado + aviso (decisão pendente)', weekend('expense', 95));
  // Recorrência.
  add(4, 'rec1', ['pago 120 de plano de saude todo dia 7 no boleto'], 'recorrente despesa 120 dia 7', recurring('expense', 120, 7));
  add(4, 'rec2', ['todo dia 25 entra 3200 do meu salário'], 'recorrente receita 3200 dia 25', recurring('income', 3200, 25));
  add(4, 'rec3', ['a mensalidade da faculdade é 890 e vence dia 12 todo mês'], 'recorrente despesa 890 dia 12', recurring('expense', 890, 12));
  add(4, 'rec4', ['cai todo mês 450 de aluguel do quartinho no dia 3'], 'recorrente receita 450 dia 3', recurring('income', 450, 3));
  add(4, 'rec5', ['mensalidade do inglês 230 dia 18 de cada mes no pix'], 'recorrente despesa 230 dia 18', recurring('expense', 230, 18));
  // Multi-turno: data corrigida.
  add(4, 'mt1', ['paguei 66 de lanche amanha no pix', 'nao, foi anteontem'], 'pergunta ⏎ grava anteontem', onceOn('expense', 66, {-2}));
  add(4, 'mt2', ['gastei 140 no conserto da maquina de lavar no pix', 'foi segunda'], 'grava ⏎ data vira segunda ${_dayLabel(_mon)}',
      onceOn('expense', 140, {_mon}));
  add(4, 'mt3', ['comprei um presente de 85 semana que vem no pix', 'opa, errei, foi ontem'], 'pergunta ⏎ grava ontem', onceOn('expense', 85, {-1}));

  // ── Eixo 5: rascunho pendente × assunto novo ──
  // Respostas que completam o rascunho.
  final answers = <List<Object>>[
    ['comprei o bolo da festa', 'cento e dez', 'expense', 110.0],
    ['paguei o chaveiro', '35 conto', 'expense', 35.0],
    ['me pagaram o frete', '220 no pix', 'income', 220.0],
    ['gastei na conveniência do posto', '19,90', 'expense', 19.9],
    ['paguei o motorista do app', 'R\$ 31', 'expense', 31.0],
    ['comprei ração', '89 no débito ontem', 'expense', 89.0, -1],
    ['paguei a revisão do carro', 'oitocentos e quarenta', 'expense', 840.0],
    ['vendi meu fogão velho', 'trezentos no pix', 'income', 300.0],
    ['paguei o dentista', 'saiu 250 conto, cartão de débito', 'expense', 250.0],
    ['abasteci a moto', '45', 'expense', 45.0],
    ['dei um dinheiro pro pedreiro da obra', 'R\$ 1.500', 'expense', 1500.0],
    ['comprei pão', '8 reais', 'expense', 8.0],
    ['paguei a manicure', 'foram trinta e cinco reais via pix viu', 'expense', 35.0],
    ['quitei a mensalidade da associação recreativa', '150', 'expense', 150.0],
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
  // "passa"/"muda" sozinhos.
  add(5, 'pm1', ['paguei o estacionamento', 'passa'], 'nada gravado/alterado', nothingSaved);
  add(5, 'pm2', ['gastei 28 no pastel no pix', 'paguei o eletricista', 'muda'], 'pastel 28 intacto; eletricista não gravado', (c) {
    if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
    final a = c.added;
    if (a.length != 1 || a.single.amount != 28) return _fail('P0', c, 'pastel alterado ou lançamento extra');
    return null;
  }, settle: false);
  add(5, 'pm3', ['comprei um guarda chuva de 40 no pix', 'muda', 'pra 45'], 'muda ⏎ pra 45 edita o guarda-chuva', (c) {
    final a = c.added;
    if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
    if (a.length != 1) return _fail('P0', c, '${a.length} lançamentos');
    if (a.single.amount == 45) return null;
    return _fail('P1', c, 'não editou para 45');
  }, settle: false);
  add(5, 'pm4', ['jantei no japa e torrei 70 no pix', 'passa', 'paguei trinta no estacionamento rotativo do centro pelo pix'], 'sushi 70 intacto + novo 30', (c) {
    final a = c.added;
    if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
    final amts = a.map((t) => t.amount).toList()..sort();
    if (amts.length == 2 && amts[0] == 30 && amts[1] == 70) return null;
    if (amts.length == 1 && amts.single == 70) return _fail('P1', c, 'frase nova perdida');
    return _fail('P0', c, 'sushi reescrito: $amts');
  });
  add(5, 'pm5', ['gastei 15 de sorvete no pix', 'muda', 'recebi 200 do meu pai no pix'], 'sorvete 15 intacto + receita 200', (c) {
    final a = c.added;
    if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
    final ok15 = a.any((t) => t.amount == 15 && t.type == TransactionType.expense);
    final ok200 = a.any((t) => t.amount == 200 && t.type == TransactionType.income);
    if (ok15 && ok200 && a.length == 2) return null;
    if (!ok15) return _fail('P0', c, 'sorvete reescrito');
    return _fail('P1', c, 'receita não registrada');
  });
  // Frase nova completa com rascunho pendente.
  add(5, 'new1', ['paguei o tecnico do ar condicionado', 'gastei 26 de uber pra voltar no pix'], 'despesa 26 (frase nova)',
      one('expense', 26, notTitle: 'ar condicionado'));
  add(5, 'new2', ['comprei umas plantas', 'caiu 1300 do seguro desemprego no pix'], 'receita 1300', one('income', 1300, notTitle: 'planta'));
  add(5, 'new3', ['paguei o cartório', 'almocei por 34 no débito'], 'despesa 34 (frase nova)', one('expense', 34, notTitle: 'cartorio'));
  add(5, 'new4', ['fiz a unha', 'me transferiram 90 do bolão no pix'], 'receita 90', one('income', 90, notTitle: 'unha'));
  add(5, 'new5', ['comprei tinta pra parede', 'lanchei um pão de queijo e um pingado, 12 pila no pix'], 'despesa 12', one('expense', 12, notTitle: 'tinta'));
  add(5, 'new6', ['paguei o gás', 'xerox 5 e grampo 3 no dinheiro'], 'lote novo 5+3 substitui o rascunho', many([5, 3]));
  // Frase nova sem valor.
  add(5, 'nov1', ['paguei a diarista', 'comprei um sapato'], 'frase nova sem valor: não funde', notMerged, settle: false);
  add(5, 'nov2', ['gastei com a farmacia', 'recebi meu pagamento'], 'frase nova sem valor: não funde', notMerged, settle: false);
  add(5, 'nov3', ['comprei peças da bicicleta', 'paguei a academia'], 'frase nova sem valor: não funde', notMerged, settle: false);
  // Perguntas no meio.
  add(5, 'q1', ['comprei um ventilador', 'qual meu saldo?'], 'responde o saldo; nada gravado', answeredNoSave);
  add(5, 'q2', ['paguei a conta do celular', 'me fala o total de saídas do mês até agora'], 'responde; nada gravado', answeredNoSave);
  add(5, 'q3', ['paguei o mecanico', 'quanto gastei ontem?', '380 no pix'], 'responde ⏎ 380 vira despesa (ou pergunta o que foi)', (c) {
    if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
    final a = c.added;
    if (a.isEmpty) return c.pendingInfo.isNotEmpty ? null : _fail('P1', c, 'perdeu o "380"');
    if (a.length == 1 && a.single.amount == 380 && a.single.type == TransactionType.expense) {
      return _fold(a.single.title).contains('mec') ? null : _fail('P2', c, 'perdeu o contexto (mecânico) depois da pergunta');
    }
    return _fail('P0', c, 'gravou errado');
  });
  // Não-eventos com número que não é valor.
  add(5, 'ne1', ['gastei no restaurante', 'o garçom era muito simpatico'], 'não grava', nothingSaved);
  add(5, 'ne2', ['paguei o uber', 'era umas 7 da noite'], 'não grava (7 é hora)', nothingSaved);
  add(5, 'ne3', ['comprei bala pros meninos', 'eles tem 5 e 8 anos'], 'não grava (idades)', nothingSaved);
  add(5, 'ne4', ['paguei a feira', 'nossa tava lotada hoje'], 'não grava', nothingSaved);
  add(5, 'ne5', ['paguei o conserto do notebook', 'demorou 2 semanas pra ficar pronto'], 'não grava (2 semanas)', nothingSaved);
  // Cancelar.
  add(5, 'can1', ['comprei uma calça', 'deixa pra lá'], 'descarta', (c) => nothingSaved(c) ?? (c.pendingInfo.isEmpty ? null : _fail('P1', c, 'rascunho continua')));
  add(5, 'can2', ['paguei o seguro', 'larga mão disso, outra hora resolvo'], 'descarta', (c) => nothingSaved(c) ?? (c.pendingInfo.isEmpty ? null : _fail('P1', c, 'rascunho continua')));
  add(5, 'can3', ['gastei no shopping', 'cancela isso'], 'descarta', (c) => nothingSaved(c) ?? (c.pendingInfo.isEmpty ? null : _fail('P1', c, 'rascunho continua')));
  // Dois números na resposta.
  add(5, 'two1', ['paguei o caminhão de frete da mudança da sogra', '250 ou 280'], 'pergunta qual, não grava', noRecordAsks, settle: false);
  // Respostas de pagamento/data.
  add(5, 'pay1', ['gastei 47 no hortifruti', 'débito'], 'despesa 47 no débito', one('expense', 47, pay: 'debit_card'));
  add(5, 'pay2', ['comprei um livro de 60', 'foi no pix ontem'], 'despesa 60 ontem', one('expense', 60, days: {-1}, pay: 'pix'));
  // Conversas de 3–5 turnos com mudança de assunto.
  add(5, 'conv1', ['oi cesar', 'paguei o encanador', 'ah antes que eu esqueça recebi 400 da minha mãe no pix', '180 do encanador no pix'],
      'receita 400 + despesa 180', (c) {
    if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro existente');
    final a = c.added;
    final inc = a.where((t) => t.amount == 400 && t.type == TransactionType.income).length;
    final exp = a.where((t) => t.amount == 180 && t.type == TransactionType.expense).length;
    if (a.any((t) => t.amount == 400 && t.type != TransactionType.income) || a.any((t) => t.amount == 180 && t.type == TransactionType.income)) {
      return _fail('P0', c, 'tipo errado');
    }
    if (a.length > inc + exp) return _fail('P0', c, 'lançamento extra');
    if (inc == 1 && exp == 1) return null;
    if (inc == 1 && _openSlots(c).isNotEmpty) return _fail('P2', c, 'encanador ficou perguntando');
    return _fail('P1', c, 'faltou lançamento');
  });
  add(5, 'conv2', ['bom dia', 'gastei 22 de pão e leite no pix', 'quanto gastei hoje?', 'e ontem?'], 'um lançamento 22; perguntas respondidas', (c) {
    final o = one('expense', 22)(c);
    if (o != null) return o;
    if (c.lastReply.route == 'ask' || c.lastReply.route == 'saved') return _fail('P1', c, '"e ontem?" não respondida');
    return null;
  });
  add(5, 'conv3', ['paguei o gás', 'peraí', '130 no dinheiro'], 'despesa 130 (peraí não é resposta)', one('expense', 130));
  add(5, 'conv4', ['comprei um bolo', 'opa me enganei era uma torta salgada', '45 no pix'], 'despesa 45', one('expense', 45));
  add(5, 'conv5', ['recebi da cliente', 'ela pagou só metade', '200'], 'receita 200', one('income', 200));

  // ── Eixo 6: referência nome × data ──
  final edits = <List<Object>>[
    ['a borracharia de sexta foi 65', 'bor', 'a', 65.0],
    ['troca o valor da sapataria de segunda pra 80', 'sap', 'a', 80.0],
    ['hamburgueria do domingo na real deu 58', 'hamb', 'a', 58.0],
    ['a papelaria de terça foi no dinheiro', 'pap', 'p', 'cash'],
    ['muda a floricultura de ontem pra 95', 'flor', 'a', 95.0],
    ['o pet shop de hoje foi 120', 'pet', 'a', 120.0],
    ['a clínica do dia ${_domOf(_clinOff)} foi 280', 'clin', 'a', 280.0],
    ['na verdade a borracharia foi 62', 'bor', 'a', 62.0],
    ['corrige a padaria sábado pra 26', 'padsab', 'a', 26.0],
    ['o mercado terça de sexta foi 128', 'merc', 'a', 128.0],
    ['a barbearia de sábado foi 50', 'barb1', 'a', 50.0],
    ['aquela sapataria de segunda foi no credito', 'sap', 'p', 'credit_card'],
    ['ajusta a hamburgueria pra 55', 'hamb', 'a', 55.0],
    ['aquela gasolina da segunda-feira na real custou 210', 'posto', 'a', 210.0],
    ['na vdd o pet shop foi 115', 'pet', 'a', 115.0],
    ['cesar a papelaria de anteontem custou 21', 'pap', 'a', 21.0],
    ['o açougue lá da quinta passada saiu por 90 conto', 'acou', 'a', 90.0],
    ['o açougue foi 92 viu', 'acou', 'a', 92.0],
    ['e a sapataria, foi 78 na verdade', 'sap', 'a', 78.0],
    ['aumenta a floricultura pra 100', 'flor', 'a', 100.0],
  ];
  for (var i = 0; i < edits.length; i++) {
    final e = edits[i];
    final f = e[2] == 'a' ? (FinancialTransaction t) => t.amount == e[3] : (FinancialTransaction t) => t.paymentMethod == e[3];
    add(6, 'ed${i + 1}', [e[0] as String], '${e[1]} → ${e[3]}', onlyThis(e[1] as String, ok: f, askOk: true), settle: false);
  }
  final dels = <List<String>>[
    ['manda pro lixo a floricultura que lancei ontem', 'sim', 'flor'],
    ['remove a borracharia de sexta', 'pode', 'bor'],
    ['exclui a padaria sábado', 'sim', 'padsab'],
    ['tira a barbearia do dia ${_domOf(_barb2Off)}', 'confirmo', 'barb2'],
    ['deleta o mercado terça', 'isso', 'merc'],
  ];
  for (var i = 0; i < dels.length; i++) {
    final d = dels[i];
    add(6, 'del${i + 1}', [d[0], d[1]], 'apaga só ${d[2]} após confirmar', onlyThis(d[2], deleted: true), settle: false);
  }
  final wrong = <List<String?>>[
    ['a borracharia de domingo foi 65', 'Borracharia', null],
    ['a sapataria de terça foi 80', 'Sapataria', 'Papelaria'],
    ['o pet shop de ontem foi 120', 'Pet Shop', 'Floricultura'],
    ['a floricultura de segunda foi 95', 'Floricultura', 'Sapataria'],
    ['a clínica do dia ${_domOf(_clinOff) == 18 ? 19 : 18} foi 280', 'Clínica', null],
    ['a hamburgueria de sábado deu 58', 'Hamburgueria', 'Quitanda'],
  ];
  for (var i = 0; i < wrong.length; i++) {
    final w = wrong[i];
    add(6, 'wr${i + 1}', [w[0]!], 'não muda; sugere ${w[1]}${w[2] != null ? ', não ${w[2]}' : ''}', untouched(w[1]!, distractor: w[2]), settle: false);
  }
  add(6, 'sg1', ['a borracharia de domingo foi 65', 'sim'], 'sugestão aceita: bor → 65', onlyThis('bor', ok: (t) => t.amount == 65), settle: false);
  add(6, 'sg2', ['o pet shop de ontem foi 120', 'é esse'], 'sugestão aceita: pet → 120', onlyThis('pet', ok: (t) => t.amount == 120), settle: false);
  add(6, 'sg3', ['pode deletar o lançamento da sapataria terça-feira', 'sim', 'sim'], 'sugestão + confirmação: apaga só sap', onlyThis('sap', deleted: true), settle: false);
  add(6, 'sg4', ['a hamburgueria de sábado deu 58', 'não'], 'recusa: nada muda', nothingSaved, settle: false);
  // Duas candidatas (duas barbearias).
  add(6, 'mu1', ['a barbearia foi 48'], 'duas barbearias: pergunta qual; nada muda', (c) {
    if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou sem saber qual');
    return null;
  }, settle: false);
  add(6, 'mu2', ['a barbearia foi 48', 'sim'], '2+ sugestões + "sim": pergunta qual; nada muda', (c) {
    if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mudou sem saber qual');
    if (c.lastReply.route == 'unknown') return _fail('P2', c, '"sim" à lista caiu na resposta genérica em vez de "qual deles?"');
    return null;
  }, settle: false);
  add(6, 'mu3', ['a barbearia foi 48', 'a de sábado'], 'escolhe barb1 → 48', onlyThis('barb1', ok: (t) => t.amount == 48), settle: false);
  add(6, 'mu4', ['apaga a barbearia', 'sim'], 'duas candidatas: não apaga sem saber qual', (c) {
    if (c.added.isNotEmpty || c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'apagou sem saber qual');
    if (c.lastReply.route == 'unknown') return _fail('P2', c, '"sim" à lista caiu na resposta genérica em vez de "qual deles?"');
    return null;
  }, settle: false);
  add(6, 'wd1', ['some com aquele registro da lanchonete ontem', 'sim'], 'não apaga a Floricultura', noWrongDelete('Floricultura'), settle: false);
  add(6, 'wd2', ['apaga a loterica de domingo', 'sim'], 'não apaga a Hamburgueria', noWrongDelete('Hamburgueria'), settle: false);
  add(6, 'no1', ['aquela lavanderia que paguei ontem custou 30'], 'não mexe em registro existente', existingIntact, settle: false);
  add(6, 'no2', ['muda pra 70 o salão de sexta'], 'não mexe em registro existente', existingIntact, settle: false);
  add(6, 'no3', ['passa 80 pro meu filho'], '"passa N pra pessoa" não edita nada', existingIntact, settle: false);
  // "na verdade o X foi N" depois de lançar outra coisa.
  add(6, 'nv1', ['gastei 33 no estacionamento no pix', 'na verdade a quitanda foi 43'], 'quit → 43; estacionamento 33 intacto',
      onlyThis('quit', ok: (t) => t.amount == 43, newAmount: 33), settle: false);
  add(6, 'nv2', ['paguei 18 no café no pix', 'opa errei o valor, foram 20'], 'o café (último) vira 20', (c) {
    if (c.removed.isNotEmpty || c.changed.isNotEmpty) return _fail('P0', c, 'mexeu em registro antigo');
    if (c.added.length == 1 && c.added.single.amount == 20) return null;
    return _fail('P1', c, 'não corrigiu o último');
  }, settle: false);
  add(6, 'nv3', ['comprei 2 cadernos por 30 no pix', 'na real a papelaria de terça foi 25'], 'pap → 25; cadernos 30 intacto',
      onlyThis('pap', ok: (t) => t.amount == 25, newAmount: 30), settle: false);

  return cs;
}

// ─────────────────────────── execução ───────────────────────────

String? _settleAnswer(SimC s) {
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

  test('ACCC lote A r3 — revalidação final', () {
    final cases = buildCases();
    final pass = <int, int>{}, total = <int, int>{};
    final sevCount = <String, int>{};
    print('ACCC_INFO|hoje=${_dm(_today)} weekday=${_today.weekday} mesPassado=${_lastMonth.month} casos=${cases.length}');
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
      final sim = SimC(engine, repo);
      final before = {for (final t in repo.transactions) t.id: jsonEncode(t.toJson())};
      final remBefore = repo.reminders.length;
      final turns = <String>[];
      final replies = <R3Reply>[];
      final activeDesc = <String?>[];
      String? crash;
      String? settleOnce() {
        if (!k.settle) return null;
        for (var i = 0; i < 3; i++) {
          final ans = _settleAnswer(sim);
          if (ans == null) break;
          turns.add('[$ans]');
          replies.add(sim.send(ans));
        }
        return null;
      }

      try {
        for (var i = 0; i < k.turns.length; i++) {
          final t = k.turns[i];
          turns.add(t);
          replies.add(sim.send(t));
          final a = sim.active;
          activeDesc.add(a != null && !a.isComplete ? a.description : null);
          // Entre turnos de uma conversa, a sonda só responde pagamento/parcelas
          // depois do último turno (para não atropelar a pergunta do eixo).
        }
        settleOnce();
      } catch (e) {
        crash = '$e';
      }
      final ctx = Ctx(sim, turns, replies, before, remBefore, activeDesc);
      final o = crash != null ? Outcome('P1', 'EXCEÇÃO: $crash') : k.check(ctx);
      total[k.axis] = (total[k.axis] ?? 0) + 1;
      if (o == null) {
        pass[k.axis] = (pass[k.axis] ?? 0) + 1;
        print('ACCC_OK|${k.axis}|${k.id}|${turns.join(' ⏎ ')}|${ctx.summary}');
      } else {
        sevCount[o.sev] = (sevCount[o.sev] ?? 0) + 1;
        print('ACCC_FAIL|${k.axis}|${k.id}|${o.sev}|${turns.join(' ⏎ ')}|${k.expected}|${o.got}');
      }
    }
    var p = 0, t = 0;
    for (final a in total.keys.toList()..sort()) {
      final ok = pass[a] ?? 0, all = total[a]!;
      p += ok;
      t += all;
      print('ACCC_AXIS|$a|$ok/$all|${(ok * 100 / all).toStringAsFixed(1)}%');
    }
    print('ACCC_TOTAL|$p/$t|${(p * 100 / t).toStringAsFixed(1)}%|sev=$sevCount');
  });
}
