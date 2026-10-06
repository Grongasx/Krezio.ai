// Teste do caos, rodada 3 (cesar-chaos) — suporte compartilhado.
//
// Não é teste (não termina em _test.dart). Usado pelos arquivos
// `chaos_r3_*_test.dart`, que só imprimem (prefixo `CHAOS-R3|`) e nunca falham
// a suíte.
//
// `Sim3` espelha `_sendMessage` de
// lib/frontend/features/chat/presentation/screens/chat_screen.dart na ordem
// atual (incl. `recordExternalEdit` no vencimento do recorrente e o `takeNotice`
// do CesarAssistant), com relógio injetável no CesarAssistant.
import 'dart:convert';

import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/cesar_text.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/goal_parser.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

class R3Reply {
  final String route;
  final String text;
  final FinancialTransactionDraft? draft;
  R3Reply(this.route, this.text, [this.draft]);

  String get short {
    final t = text.replaceAll('\n', ' ');
    return '[$route] ${t.length > 150 ? '${t.substring(0, 150)}…' : t}';
  }
}

class Sim3 {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  FinancialTransactionDraft? active;
  FinancialTransactionDraft? last;
  List<String> lastIds = const [];
  List<FinancialTransactionDraft>? pendingBatch;

  /// Quantas vezes o chat chamou recordCreated neste turno.
  int chatPushes = 0;
  static int _goalSeq = 0;

  Sim3(this.engine, this.repo, {DateTime Function()? now}) : assistant = CesarAssistant(repository: repo, engine: engine, now: now);

  R3Reply send(String input) {
    chatPushes = 0;
    final r = _send(input.trim());
    final notice = assistant.takeNotice();
    if (notice != null) return R3Reply(r.route, '$notice\n\n${r.text}', r.draft);
    return r;
  }

  void _saved(List<String> ids) {
    lastIds = ids;
    if (ids.isNotEmpty) chatPushes++;
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
      repo.addGoal(FinancialGoal(id: 'goal-r3-${++_goalSeq}', title: goalCreation.title, targetAmount: goalCreation.targetAmount, targetDate: goalCreation.targetDate));
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
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      _saved(repo.addTransactionFromDraft(draft).map((t) => t.id).toList());
      if (draft.isReminder) {
        repo.addReminder(FinancialReminder(
          id: 'rem-r3-${repo.reminders.length + 1}-${DateTime.now().microsecondsSinceEpoch}',
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

// ───────────────────────── estado ─────────────────────────

class Snap3 {
  final Map<String, String> tx;
  final Map<String, String> budgets;
  final Map<String, String> goals;
  final Map<String, String> overrides;
  Snap3(this.tx, this.budgets, this.goals, this.overrides);

  factory Snap3.of(FinancialRepository r) => Snap3(
        {for (final t in r.transactions) t.id: jsonEncode(t.toJson())},
        {for (final b in r.budgets) b.category: '${b.name}|${b.monthlyLimit}|${b.isCustom}'},
        {for (final g in r.goals) g.id: '${g.title}|${g.targetAmount}|${g.savedAmount}|${g.isCompleted}'},
        Map<String, String>.from(r.categoryOverrides),
      );

  static bool _eq(Map<String, String> a, Map<String, String> b) => a.length == b.length && a.keys.every((k) => b[k] == a[k]);

  /// Sem a memória de categoria (ela não entra no desfazer por desenho — ver achado próprio).
  bool sameData(Snap3 o) => _eq(tx, o.tx) && _eq(budgets, o.budgets) && _eq(goals, o.goals);
  bool sameAll(Snap3 o) => sameData(o) && _eq(overrides, o.overrides);

  String diff(Snap3 o, {bool withOverrides = false}) {
    final out = <String>[];
    void d(String name, Map<String, String> a, Map<String, String> b) {
      for (final k in {...a.keys, ...b.keys}) {
        if (a[k] != b[k]) {
          String short(String? v) => v == null ? '∅' : (v.length > 110 ? '${v.substring(0, 110)}…' : v);
          out.add('$name[$k]: ${short(a[k])} → ${short(b[k])}');
        }
      }
    }

    d('tx', tx, o.tx);
    d('budget', budgets, o.budgets);
    d('goal', goals, o.goals);
    if (withOverrides) d('override', overrides, o.overrides);
    return out.take(4).join(' ; ');
  }
}

double money2(double v) => (v * 100).roundToDouble() / 100;

final yesRe = RegExp(
    r'^(?:sim|s|isso|pode|pode sim|pode apagar|pode excluir|apaga|apague|exclui|confirmo|confirma|confirmado|claro|ok|okay|beleza|blz|manda|manda ver|com certeza|certeza|yes|uhum|aham|isso mesmo|sim pode|sim apaga|sim por favor)(?:\s+(?:sim|pode|apagar|apaga|por favor|cesar|isso))*$');

/// Invariantes estáticos do repositório. Devolve a lista de problemas.
List<String> repoInvariants(FinancialRepository repo, {DateTime? now}) {
  final out = <String>[];
  final ids = repo.transactions.map((x) => x.id).toList();
  if (ids.toSet().length != ids.length) out.add('id_duplicado: ${ids.length - ids.toSet().length}');
  for (final x in repo.transactions) {
    if (!x.amount.isFinite || x.amount < 0.01) out.add('valor_invalido: ${x.title} ${x.amount}');
  }
  var inc = 0.0, exp = 0.0;
  for (final x in repo.transactions) {
    if (x.type == TransactionType.income) {
      inc += x.amount;
    } else {
      exp += x.amount;
    }
  }
  if ((inc - exp - repo.totalBalance).abs() > 0.005) out.add('saldo: ${inc - exp} ≠ ${repo.totalBalance}');
  final n = now ?? DateTime.now();
  for (final b in repo.budgets) {
    final spent = repo.transactions
        .where((x) => x.type == TransactionType.expense && x.category == b.category && x.date.year == n.year && x.date.month == n.month)
        .fold(0.0, (a, x) => a + x.amount);
    if ((money2(spent) - money2(b.currentSpent)).abs() > 0.005) out.add('currentSpent: ${b.name} ${b.currentSpent} ≠ $spent');
    if (!b.monthlyLimit.isFinite || b.monthlyLimit < 0) out.add('limite_invalido: ${b.name} ${b.monthlyLimit}');
  }
  final codes = repo.budgets.map((b) => b.category).toList();
  if (codes.toSet().length != codes.length) out.add('categoria_duplicada: $codes');
  final names = repo.budgets.map((b) => CesarText.fold(b.name)).toList();
  if (names.toSet().length != names.length) out.add('nome_categoria_duplicado: $names');
  final gids = repo.goals.map((g) => g.id).toList();
  if (gids.toSet().length != gids.length) out.add('meta_id_duplicado');
  for (final g in repo.goals) {
    if (!g.savedAmount.isFinite || g.savedAmount < 0) out.add('meta_saldo_invalido: ${g.title} ${g.savedAmount}');
    if (g.isCompleted != (g.savedAmount >= g.targetAmount)) out.add('meta_isCompleted_incoerente: ${g.title} ${g.savedAmount}/${g.targetAmount} ${g.isCompleted}');
  }
  return out;
}

String describeTx(String json) {
  final m = jsonDecode(json) as Map;
  return '${m['title']} ${m['amount']} ${m['date']}';
}
