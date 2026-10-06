import '../backend/models/budget_category.dart';
import '../backend/models/financial_goal.dart';
import '../backend/models/financial_transaction.dart';
import '../backend/repositories/financial_repository.dart';
import 'category_command_parser.dart';
import 'goal_command_parser.dart';
import 'cesar_small_talk.dart';
import 'cesar_text.dart';
import 'chat_action_history.dart';
import 'financial_qa_engine.dart';
import 'affordability_analyzer.dart';
import 'financial_report_rag_engine.dart';
import 'hypothesis_detector.dart';
import 'local_nlp_engine.dart';
import 'pending_reply_check.dart';
import 'reference_edit_parser.dart';
import 'transaction_command_parser.dart';
import 'transaction_reference_resolver.dart';

/// What César says back for a message the assistant handled.
class AssistantReply {
  final String text;
  final String spokenText;

  /// Short route name for logs/QA batteries ("report:spending", "deleted",
  /// "confirm_delete", "edited", "undo", "help"…).
  final String route;
  final ReportChartData? chart;

  /// Records that no longer exist because of this reply (deleted, or an
  /// undone creation) — the chat drops them from its own "last" state.
  final Set<String> removedIds;

  /// Records whose values changed (edited or restored by an undo).
  final Set<String> changedIds;

  /// Not a reply: the message rewritten as a full entry for the normal
  /// pipeline ("e 30 na padaria" → "gastei 30 na padaria no pix"), which
  /// asks whatever is still missing.
  final String? rewrittenInput;

  const AssistantReply(
    this.text, {
    String? spokenText,
    required this.route,
    this.chart,
    this.removedIds = const {},
    this.changedIds = const {},
    this.rewrittenInput,
  }) : spokenText = spokenText ?? text;

  @override
  String toString() => '[$route] $text';
}

enum _PendingKind { confirmDelete, chooseTarget, awaitChanges, confirmCategoryDelete, confirmGoalDelete, correctionOrNew, offerSuggestion }

class _Pending {
  final _PendingKind kind;
  final List<FinancialTransaction> targets;
  final ChatCommand? command;
  final BudgetCategory? category;
  final FinancialGoal? goal;
  const _Pending(this.kind, this.targets, [this.command, this.category, this.goal]);
}

/// César's conversational brain for everything beyond recording a new
/// transaction: editing and deleting any record by reference (with
/// confirmation before deleting), undo, free-language corrections of the last
/// entry, and questions about the data with follow-ups ("e ontem?"). The
/// chat screen and the voice controller share one instance, so both see the
/// same history and context.
///
/// Pure Dart, no Flutter. The UI calls, for every user message:
/// 1. [beginTurn];
/// 2. [handleCommand] early (right after cancelling a pending draft) — a
///    non-null reply means the message was handled;
/// 3. [handleQuestion] where reports used to be answered;
/// and [recordCreated] whenever it saves new transactions.
class CesarAssistant {
  final FinancialRepository repository;
  final LocalFinancialNlpEngine engine;
  final DateTime Function() _clock;
  final ChatActionHistory history = ChatActionHistory();

  CesarAssistant({required this.repository, required this.engine, DateTime Function()? now}) : _clock = now ?? DateTime.now;

  int _turn = 0;
  int _lastMutationTurn = -10;
  int _lastQaTurn = -10;
  QaQuery? _lastQuery;
  _Pending? _pending;
  String? _notice;

  /// Id groups the chat created, oldest first (a daily-rate entry is one
  /// group of several ids). "o último"/"o anterior" index into this.
  final List<List<String>> _groups = [];

  /// Turn in which each record the chat created was saved: "o primeiro"
  /// counts from the entries of the current stretch of conversation, and a
  /// record just made is a safe target for "o almoço foi 36".
  final Map<String, int> _createdTurn = {};

  /// What "esse"/"o último" means right now: the last record César created
  /// or changed.
  List<String> _focus = const [];

  FinancialQaEngine get _qa => FinancialQaEngine(repository: repository, now: _clock);

  /// Whether César is waiting for a yes/no or a choice from a list.
  bool get hasPendingQuestion => _pending != null;

  /// The last question's parts, for follow-ups (exposed for tests).
  QaQuery? get lastQuery => _lastQuery;

  int? _seenGeneration;

  /// The last record in focus was deleted: "esse"/"muda pra 80" must ask
  /// which one instead of falling back to an older record (R2-CHAOS-018).
  bool _focusDeleted = false;

  void beginTurn() {
    _turn++;
    // "Limpar Histórico" or a cloud snapshot replaced everything: what this
    // conversation remembers (undo stack, "o último", pending questions) is
    // about records that are gone. Before, "desfaz" after a clear brought a
    // deleted record back into the empty app (R2-CHAOS-012).
    final generation = repository.dataGeneration;
    if (_seenGeneration != null && _seenGeneration != generation) {
      history.clear();
      _groups.clear();
      _focus = const [];
      _focusDeleted = false;
      _pending = null;
    }
    _seenGeneration = generation;
  }

  /// A note for the chat to put before its own reply ("Ok, não apaguei
  /// nada.") when a pending confirmation was dropped by an unrelated message.
  String? takeNotice() {
    final n = _notice;
    _notice = null;
    return n;
  }

  /// The chat saved new record(s) — one group — as the user's last entry.
  void recordCreated(List<String> ids) {
    if (ids.isEmpty) return;
    final records = repository.transactions.where((t) => ids.contains(t.id)).toList();
    history.push(ChatAction(ChatActionKind.created, records));
    _groups.add(List<String>.from(ids));
    for (final id in ids) {
      _createdTurn[id] = _turn;
    }
    if (_groups.length > 50) _groups.removeAt(0);
    _focus = List.unmodifiable(ids);
    _focusDeleted = false;
    _lastMutationTurn = _turn;
  }

  /// The chat changed records through another path (e.g. a recurring due-day
  /// correction): keep the snapshot so "desfaz" can put them back.
  void recordExternalEdit(List<FinancialTransaction> before) {
    history.push(ChatAction(ChatActionKind.edited, before));
    _lastMutationTurn = _turn;
  }

  List<FinancialTransaction> _existing(List<String> ids) {
    final byId = {for (final t in repository.transactions) t.id: t};
    return ids.map((id) => byId[id]).whereType<FinancialTransaction>().toList();
  }

  /// Records "esse"/"o último" points to, or empty.
  List<FinancialTransaction> _lastTargets() {
    final focused = _existing(_focus);
    if (focused.isNotEmpty) return focused;
    if (_focusDeleted) return const [];
    for (final g in _groups.reversed) {
      final found = _existing(g);
      if (found.isNotEmpty) return found;
    }
    return const [];
  }

  // ───────────────────────── commands ─────────────────────────

  /// Edit/delete/undo/corrections and answers to César's own pending
  /// questions. [hasPendingDraft]: the chat is still asking about a new
  /// entry — then only answers to César's pending question are taken here.
  AssistantReply? handleCommand(String text, {bool hasPendingDraft = false}) {
    final pending = _pending;
    if (pending != null) {
      final reply = _answerPending(pending, text);
      if (reply != null) return reply;
    }

    // A goal deposit/withdrawal is handled here even while a draft is still
    // pending, so it enters the undo history: through the old path it didn't,
    // and the second "desfaz" deleted an older entry instead (R2-CHAOS-013).
    final goalCmd = GoalCommandParser.parse(text);
    if (goalCmd != null) {
      final reply = _runGoalCommand(goalCmd);
      if (reply != null) return reply;
    }

    if (hasPendingDraft) return _commandDuringDraft(text);

    if (TransactionCommandParser.isUndo(text)) return _undo();

    // Something that didn't (or didn't yet) happen with a value — "era pra
    // eu pagar 77 hoje mas esqueci", "tenho que pagar 7 de iptu semana que
    // vem" — never edits a record nor adds one: the free correction path
    // read it as "the last one was 77" (CHAOS-C-004). A delete still runs
    // ("apaga o 7 belo, nem cheguei a pagar").
    final nonEvent = RegExp(r'\d').hasMatch(text) && PendingReplyCheck.isNonEvent(text);

    final followUp = nonEvent ? null : _followUpEntry(text);
    if (followUp != null) return followUp;

    final sameAs = nonEvent ? null : _sameAsBefore(text);
    if (sameAs != null) return sameAs;

    final categoryCmd = CategoryCommandParser.parse(text);
    if (categoryCmd != null) return _runCategoryCommand(categoryCmd);

    final refEdit = nonEvent ? null : _referenceEdit(text);
    if (refEdit != null) return refEdit;

    final s = CesarText.simplify(text);
    final justChanged = _lastMutationTurn == _turn - 1;

    // "isso mesmo", "ok", "perfeito" right after César recorded/changed something.
    if (justChanged && engine.isConfirmation(text) && !RegExp(r'obrigad|brigad|valeu|vlw').hasMatch(s)) {
      return const AssistantReply('Combinado, fica assim mesmo! 👍', route: 'confirm');
    }

    // Just the name of one of the user's own categories right after an entry
    // ("roupas") = "put that one in this category".
    if (justChanged && s.split(' ').length <= 3 && !RegExp(r'\d').hasMatch(s)) {
      final code = engine.matchCustomCategory(text) ?? repository.findCustomCategoryCode(text);
      final targets = _lastTargets();
      if (code != null && targets.isNotEmpty) {
        return _applyEdit(targets, TransactionChanges(category: code), text);
      }
    }

    final cmd = TransactionCommandParser.parse(text, now: _clock(), budgets: repository.budgets);
    if (cmd == null) return null;
    if (nonEvent && cmd.kind != ChatCommandKind.delete) return null;
    return _runCommand(cmd, text);
  }

  /// With a draft still being asked about, a command that names another
  /// record ("apaga o do sacolão", "exclui os dois") acts on that record and
  /// says the draft was dropped (R2-CONV-007/R2-FEAT-006). Anything else
  /// stays with the draft (null).
  AssistantReply? _commandDuringDraft(String text) {
    if (!TransactionCommandParser.namesSpecificRecord(text, now: _clock(), budgets: repository.budgets)) return null;
    final cmd = TransactionCommandParser.parse(text, now: _clock(), budgets: repository.budgets)!;
    final spec = TransactionReferenceResolver.parse(cmd.reference, now: _clock());
    AssistantReply? reply;
    if (spec.lastCount != null && cmd.kind == ChatCommandKind.delete && spec.terms.isEmpty && spec.dayStart == null) {
      // "apaga os dois" with one entry saved and another still being asked
      // about: the draft is one of the two — the saved ones are the rest.
      final saved = _groups.reversed.take(spec.lastCount! - 1).expand(_existing).toList();
      if (saved.isEmpty) return const AssistantReply('Tudo bem, descartei esse lançamento. Nada foi registrado. 👍', route: 'cancel_pending');
      reply = _askDelete(saved);
    } else {
      reply = _runCommand(cmd, text);
    }
    if (reply == null || (reply.route == 'not_found' && cmd.kind == ChatCommandKind.delete)) {
      // Nothing saved by that name: "apaga o mercado" was about the draft itself.
      _pending = null;
      return const AssistantReply('Tudo bem, descartei esse lançamento. Nada foi registrado. 👍', route: 'cancel_pending');
    }
    const dropped = 'Deixei de lado o lançamento que eu estava perguntando — nada dele foi registrado.';
    return AssistantReply('$dropped\n\n${reply.text}',
        spokenText: '$dropped ${reply.spokenText}',
        route: reply.route,
        chart: reply.chart,
        removedIds: reply.removedIds,
        changedIds: reply.changedIds);
  }

  /// "o uber e o 99", "o sacolão e a banca": several records in one command.
  static List<String> _splitTargets(String ref) => CesarText.simplify(ref)
      .split(RegExp(r'\s+(?:e|mais)\s+(?=(?:o|a|os|as|aquele|aquela|esse|essa|do|da)\s)'))
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();

  /// One confirmation (or one edit) for every record named (R2-FEAT-002).
  /// Each part must point to one record; otherwise César says which part he
  /// couldn't pin down instead of acting on only some of them.
  AssistantReply? _runMultiTarget(ChatCommand cmd, List<String> parts, String text) {
    final targets = <FinancialTransaction>[];
    for (final part in parts) {
      final spec = TransactionReferenceResolver.parse(part, now: _clock());
      final r = spec.isJustLast ? null : _resolve(spec);
      if (r == null || r.matches.isEmpty || r.byCategoryOnly) {
        return AssistantReply('Não achei "$part", então não mexi em nada. Pode repetir só com os que existem?', route: 'not_found');
      }
      if (r.matches.length > 1 && !_sameGroup(r.matches)) {
        final opts = r.matches.take(3).map((t) => CesarText.describe(t, _clock())).join('; ');
        return AssistantReply('Achei mais de um lançamento para "$part" ($opts), então não mexi em nada. '
            'Me diga um de cada vez, com a data ou o valor — ex.: "${cmd.kind == ChatCommandKind.delete ? 'apaga' : 'muda'} $part de ontem".',
            route: 'choose');
      }
      for (final t in r.matches) {
        if (!targets.any((x) => x.id == t.id)) targets.add(t);
      }
    }
    return _act(cmd, targets, text);
  }

  AssistantReply? _runCommand(ChatCommand cmd, String text) {
    final List<FinancialTransaction> targets;
    final ref = cmd.reference.trim();
    final entryText = cmd.entryText;
    if (entryText != null && ref.isEmpty) return _correctionOrNewEntry(cmd, entryText);
    final parts = _splitTargets(ref);
    if (parts.length >= 2 && cmd.kind != ChatCommandKind.showForEdit) return _runMultiTarget(cmd, parts, text);
    final spec = ref.isEmpty ? const ReferenceSpec() : TransactionReferenceResolver.parse(ref, now: _clock());
    if (spec.invalidDate != null) {
      return AssistantReply('Essa data não existe (${spec.invalidDate}), então não mexi em nada. De qual dia é o lançamento? '
          'Ex.: "${cmd.kind == ChatCommandKind.delete ? 'apaga' : 'muda'} o de ontem" ou "… do dia 5".', route: 'invalid_date');
    }

    if (spec.isJustLast) {
      targets = _lastTargets();
      if (targets.isEmpty) {
        if (!cmd.strong) return null;
        if (spec.position == 1) {
          // "apaga o último" with nothing from this conversation: the newest record.
          final r = TransactionReferenceResolver.resolve(spec, all: repository.transactions, recentGroups: const [], budgets: repository.budgets);
          if (r.matches.isNotEmpty) return _act(cmd, r.matches, text);
        }
        return AssistantReply(
          cmd.kind == ChatCommandKind.delete
              ? 'Qual lançamento você quer apagar? Me diga qual, por exemplo: "apaga o uber de ontem" ou "apaga o último".'
              : 'Qual lançamento você quer corrigir? Me diga qual, por exemplo: "muda o valor do aluguel pra 1500".',
          route: 'ask_target',
        );
      }
      return _act(cmd, targets, text);
    }

    final r = _resolve(spec);
    if (r.matches.isEmpty) {
      if (!cmd.strong) return null;
      return _notFoundReply(cmd, r);
    }
    if (r.byCategoryOnly) {
      if (!cmd.strong) return null;
      // An old record saved with the category's label as its title
      // ("supermercado / feira") has no name but its category: "apaga a
      // mercearia" names it. A delete shows it and asks anyway.
      if (cmd.kind == ChatCommandKind.delete && r.matches.length == 1 && LocalFinancialNlpEngine.isCategoryLabel(r.matches.first.title)) {
        return _askDelete(r.matches);
      }
      return _offerByCategory(cmd, r);
    }
    if (r.matches.length > 1 && !spec.plural && spec.lastCount == null && !_sameGroup(r.matches)) {
      if (!cmd.strong && cmd.changes.isEmpty) return null;
      return _askChoose(cmd, r);
    }
    return _act(cmd, r.matches, text);
  }

  /// Groups the chat created in the last few turns — what "o primeiro" counts from.
  List<List<String>> _recentGroups() => _groups.where((g) => g.isNotEmpty && (_createdTurn[g.first] ?? -100) >= _turn - 8).toList();

  ReferenceResolution _resolve(ReferenceSpec spec) => TransactionReferenceResolver.resolve(spec,
      all: repository.transactions, recentGroups: spec.fromStart != null ? _recentGroups() : _groups, budgets: repository.budgets);

  /// "o do posto de terça foi 170", "aquele de 89 foi no dinheiro", "foi 26
  /// o 99 de hoje", "nem era 150 o posto, era 140": a sentence that names an
  /// existing record and brings one new field edits it (R2-CONV-004/005).
  /// Null when nothing matches — then it may be a new entry ("o almoço foi
  /// 45" with no lunch saved). When it could be either (a new value for an
  /// older record, and nothing in the sentence says it corrects), César asks.
  AssistantReply? _referenceEdit(String text) {
    final edit = ReferenceEditParser.parse(text, now: _clock(), budgets: repository.budgets);
    if (edit == null) return null;
    final spec = TransactionReferenceResolver.parse(edit.reference, now: _clock());
    if (spec.invalidDate != null || spec.isJustLast) return null;
    var r = _resolve(spec);
    if (edit.oldAmount != null && spec.amount == null) {
      final narrowed = _resolve(spec.copyWith(amount: edit.oldAmount));
      if (narrowed.matches.isNotEmpty) r = narrowed;
    }
    final demonstrative = RegExp(r'^(?:aquel|daquel)').hasMatch(CesarText.simplify(edit.reference));
    // "a feira de segunda foi 90" with the Feira on another day: say where it
    // is and ask, instead of recording a new entry or editing another one
    // (CHAOS-R3-004).
    final cmd = ChatCommand(ChatCommandKind.edit, reference: edit.reference, changes: edit.changes, entryText: text);
    if (r.matches.isEmpty) {
      final namedElsewhere = spec.dayStart != null && r.suggestions.isNotEmpty;
      if (demonstrative || namedElsewhere) return _notFoundReply(cmd, r);
      // "na verdade o açougue foi 23" with no Açougue saved: the record named
      // doesn't exist — César says so. It rewrote the last record instead,
      // even an income or an old record only just edited (CHAOS-C-006). The
      // one exception: an expense created right now ("gastei 20 no açaí" ⏎
      // "na verdade o açougue foi 23") — fixing what was just said.
      if (edit.namesRecordAfterMarker && !_justCreatedExpense()) return _notFoundReply(cmd, r);
      return null;
    }
    // Only the category ties "a feira de ontem" to the "Mercado Dia a Dia":
    // show it and ask; without anything saying it's a correction, it may be
    // a new entry (CHAOS-B-014/026).
    if (r.byCategoryOnly) return demonstrative || edit.explicitCorrection || spec.dayStart != null ? _offerByCategory(cmd, r) : null;
    if (r.matches.length > 1 && !_sameGroup(r.matches)) {
      // "o mercado foi 45" just after recording the mercado: that one.
      final focus = _lastTargets();
      if (focus.isNotEmpty && focus.every((f) => r.matches.any((m) => m.id == f.id))) {
        r = ReferenceResolution(r.spec, focus);
      } else {
        return _askChoose(cmd, r);
      }
    }
    final targets = r.matches;
    // "o mercado tava lotado hoje": nothing would change — it's a comment.
    if (_diff(targets.first, _rebuild(targets.first, edit.changes)).isEmpty) return null;
    final explicitRef = demonstrative || spec.amount != null || spec.dayStart != null || spec.fromStart != null || spec.type != null;
    final justMade = targets.every((t) => _createdTurn.containsKey(t.id) && _turn - _createdTurn[t.id]! <= 10);
    // Named by its own title ("o almoço" → "Almoço"), not only by category
    // ("a gasolina" → a "Posto" record in transport).
    final byTitle = spec.terms.isNotEmpty && targets.every((t) => spec.terms.every((w) => CesarText.fold(t.title).contains(w)));
    if (edit.changes.amount != null && !edit.explicitCorrection && !explicitRef && !(justMade && byTitle)) {
      _pending = _Pending(_PendingKind.correctionOrNew, targets, cmd);
      final what = CesarText.describe(targets.first, _clock());
      return AssistantReply(
        'É uma correção de **$what** ou um lançamento novo? (responda "correção" ou "novo")',
        spokenText: 'É uma correção de $what ou um lançamento novo?',
        route: 'ask_correction_or_new',
      );
    }
    return _applyEdit(targets, edit.changes, text);
  }

  /// The focus is an expense the chat created in this or the previous turn
  /// (not an older record, not one only edited).
  bool _justCreatedExpense() {
    final focus = _existing(_focus);
    return focus.isNotEmpty &&
        focus.every((t) => t.type == TransactionType.expense && (_createdTurn[t.id] ?? -100) >= _turn - 1 && _lastMutationTurn == _createdTurn[t.id]);
  }

  /// "Encontrei 3 lançamentos de 'padaria'. Qual você quer apagar?"
  AssistantReply _askChoose(ChatCommand cmd, ReferenceResolution r) {
    final spec = r.spec;
    {
      final options = r.matches.take(5).toList();
      _pending = _Pending(_PendingKind.chooseTarget, options, cmd);
      final verb = cmd.kind == ChatCommandKind.delete ? 'apagar' : 'mudar';
      final now = _clock();
      final list = [for (var i = 0; i < options.length; i++) '${i + 1}. ${CesarText.describe(options[i], now)}'].join('\n');
      final more = r.matches.length > options.length ? '\n(e mais ${r.matches.length - options.length})' : '';
      return AssistantReply(
        'Encontrei ${r.matches.length} lançamentos ${spec.describe()}. Qual você quer $verb?\n$list$more\n\nResponda com o número (ou "nenhum").',
        spokenText: 'Encontrei ${r.matches.length} lançamentos ${spec.describe()}. Qual você quer $verb? '
            '${[for (var i = 0; i < options.length; i++) 'Opção ${i + 1}: ${options[i].title}, ${CesarText.money(options[i].amount)}'].join('. ')}.',
        route: 'choose',
      );
    }
  }

  /// "na verdade, hoje eu gastei 20 no pastel no pix" is a whole entry after
  /// a correction marker (R2-CONV-001). It overwrote the last record even
  /// when it was obviously another purchase. Now: nothing to correct, or a
  /// different place/category → a new entry; the same place/category as the
  /// last record → ask which one it is.
  AssistantReply? _correctionOrNewEntry(ChatCommand cmd, String entryText) {
    final targets = _lastTargets();
    final newEntry = AssistantReply('', route: 'new_entry', rewrittenInput: entryText);
    if (targets.isEmpty || _turn - _lastMutationTurn > 3) return newEntry;
    final last = targets.first;
    final draft = engine.parse(entryText);
    final folded = CesarText.fold(entryText);
    final titleWords = CesarText.fold(last.title).split(RegExp(r'[^a-z0-9]+')).where((w) => w.length >= 4);
    final samePlace = titleWords.any((w) => RegExp('\\b${RegExp.escape(w)}').hasMatch(folded));
    final sameCategory = draft.category != 'unknown' && draft.category == last.category;
    if (!samePlace && !sameCategory) return newEntry;
    _pending = _Pending(_PendingKind.correctionOrNew, targets, cmd);
    final what = '${last.title} (${CesarText.money(last.amount)})';
    return AssistantReply(
      'É uma correção do **$what** ou um gasto novo? (responda "correção" ou "novo")',
      spokenText: 'É uma correção do $what ou um gasto novo?',
      route: 'ask_correction_or_new',
    );
  }

  static final _saysCorrection = RegExp(r'^(?:e\s+|foi\s+)?(?:uma\s+)?(?:correcao|corrige|corrigir|corrija|corrigi|o\s+mesmo|mesmo|esse|era\s+esse|e\s+esse|altera|substitui|troca|muda)\b');
  static final _saysNew = RegExp(r'^(?:e\s+)?(?:um\s+|uma\s+)?(?:novo|nova|outro|outra|gasto\s+novo|lancamento\s+novo|separado|registra|adiciona|lanca)\b|\bnovo\b');

  bool _sameGroup(List<FinancialTransaction> matches) {
    final ids = matches.map((t) => t.id).toSet();
    return _groups.any((g) => ids.every(g.contains));
  }

  AssistantReply _act(ChatCommand cmd, List<FinancialTransaction> targets, String text) {
    switch (cmd.kind) {
      case ChatCommandKind.delete:
        return _askDelete(targets);
      case ChatCommandKind.showForEdit:
        return _askChanges(targets);
      case ChatCommandKind.edit:
        if (cmd.changes.isEmpty) return _askChanges(targets, didNotUnderstand: true);
        return _applyEdit(targets, cmd.changes, text);
    }
  }

  /// "Não achei…; os mais próximos são…": the suggestions stay offered, so
  /// "sim"/"esse"/"pode ser" (one suggestion) or "o de 26/09" picks one and
  /// the command goes on — a delete still asks its confirmation (ACC-A-016).
  AssistantReply _notFoundReply(ChatCommand cmd, ReferenceResolution r) {
    if (r.suggestions.isNotEmpty) _pending = _Pending(_PendingKind.offerSuggestion, r.suggestions, cmd);
    return AssistantReply(_notFound(r), route: 'not_found');
  }

  /// No word said is in a title, only the category matches: the record(s)
  /// are offered, never edited/deleted directly. "sim" (one) or a number
  /// picks; then the command goes on — a delete still confirms.
  AssistantReply _offerByCategory(ChatCommand cmd, ReferenceResolution r) {
    final options = r.matches.take(3).toList();
    _pending = _Pending(_PendingKind.offerSuggestion, options, cmd);
    final now = _clock();
    final what = r.spec.describe();
    if (options.length == 1) {
      final d = CesarText.describe(options.first, now);
      return AssistantReply('Não achei nenhum lançamento $what pelo nome. O que mais combina é **$d** — é esse? (sim/não)',
          spokenText: 'Não achei nenhum lançamento $what pelo nome. O que mais combina é $d. É esse?', route: 'not_found');
    }
    final list = [for (var i = 0; i < options.length; i++) '${i + 1}. ${CesarText.describe(options[i], now)}'].join('\n');
    return AssistantReply('Não achei nenhum lançamento $what pelo nome. Os que mais combinam são:\n$list\n\nÉ algum deles? Responda com o número (ou "nenhum").',
        spokenText: 'Não achei nenhum lançamento $what pelo nome. ${[for (var i = 0; i < options.length; i++) 'Opção ${i + 1}: ${options[i].title}'].join('. ')}. É algum deles?',
        route: 'not_found');
  }

  /// A short yes to a single suggestion: "sim", "esse", "essa mesma", "pode ser".
  static bool _acceptsOffer(String s) =>
      _isYes(s) ||
      RegExp(r'^(?:(?:e|foi|era|sim)\s+)?(?:esse|essa|este|esta|ele|ela|isso|pode\s+ser|esse\s+mesmo|essa\s+mesma|isso\s+mesmo|esse\s+ai|essa\s+ai|esse\s+ai\s+mesmo|essa\s+ai\s+mesmo|o\s+mesmo|a\s+mesma)$')
          .hasMatch(s);

  String _notFound(ReferenceResolution r) {
    final what = r.spec.describe();
    if (r.suggestions.isNotEmpty) {
      final dates = r.suggestions.map((t) => '${t.title} em ${CesarText.ddmm(t.date)} (${CesarText.money(t.amount)})').join(', ');
      final prefix = r.spec.dateLabel != null ? 'Não achei nenhum lançamento $what.' : 'Não achei esse lançamento.';
      return '$prefix Os mais próximos são: $dates. Quer mexer em algum deles? '
          'É só dizer, por exemplo, "muda o de ${CesarText.ddmm(r.suggestions.first.date)}".';
    }
    return 'Não achei nenhum lançamento $what. Pergunte "quais foram meus últimos lançamentos?" para ver a lista.';
  }

  AssistantReply _askDelete(List<FinancialTransaction> targets) {
    _pending = _Pending(_PendingKind.confirmDelete, targets);
    final now = _clock();
    if (targets.length == 1) {
      final d = CesarText.describe(targets.first, now);
      return AssistantReply('Vou apagar **$d**. Confirma? (sim/não)', spokenText: 'Vou apagar $d. Confirma?', route: 'confirm_delete');
    }
    final total = targets.fold(0.0, (a, t) => a + t.amount);
    final list = targets.take(10).map((t) => '- ${CesarText.describe(t, now)}').join('\n');
    return AssistantReply(
      'Vou apagar ${targets.length} lançamentos (${CesarText.money(total)} no total):\n$list\n\nConfirma? (sim/não)',
      spokenText: 'Vou apagar ${targets.length} lançamentos, somando ${CesarText.money(total)}. Confirma?',
      route: 'confirm_delete',
    );
  }

  AssistantReply _askChanges(List<FinancialTransaction> targets, {bool didNotUnderstand = false}) {
    _pending = _Pending(_PendingKind.awaitChanges, targets);
    final t = targets.first;
    final cat = CesarText.categoryName(t.category, repository.budgets);
    final d = '${t.title} — ${CesarText.money(t.amount)}, ${CesarText.paymentName(t.paymentMethod)}, '
        '${CesarText.relativeDay(t.date, _clock())}, $cat (${CesarText.typeName(t.type)})';
    final lead = didNotUnderstand ? 'Não entendi o que mudar em' : 'Esse é o lançamento:';
    return AssistantReply(
      '$lead **$d**.\nO que você quer mudar? Pode ser o valor, a data, a categoria, o tipo ou a forma de pagamento — '
      'ex.: "45", "foi ontem", "é lazer", "foi no débito".',
      spokenText: '$lead $d. O que você quer mudar?',
      route: 'ask_changes',
    );
  }

  static bool _isYes(String s) => RegExp(
          r'^(?:sim|s|isso|pode|pode sim|pode apagar|pode excluir|apaga|apague|exclui|confirmo|confirma|confirmado|claro|ok|okay|beleza|blz|manda|manda ver|com certeza|certeza|yes|uhum|aham|isso mesmo|sim pode|sim apaga|sim por favor)(?:\s+(?:sim|pode|apagar|apaga|por favor|cesar|isso))*$')
      .hasMatch(s);

  static bool _isNo(String s) => RegExp(
          r'^(?:nao|n|nem|negativo|cancela|cancelar|deixa|deixa pra la|esquece|melhor nao|nao apaga|nao precisa|para|pare|nenhum|nenhuma|nada|nao quero|deixa quieto)\b')
      .hasMatch(s);

  /// The check every waiting state shares ([PendingReplyCheck]): a command,
  /// a question, something that didn't happen or an entry with its own story
  /// is not the answer to "o que você quer mudar?", "é esse?", "qual deles?"
  /// or "correção ou novo?" — it is read as a new message (7d, CHAOS-B-012).
  TopicShift _shiftFrom(_Pending pending, String text) {
    final t = pending.targets.isEmpty ? null : pending.targets.first;
    final subject = PendingSubject(
      t == null ? (pending.command?.reference ?? '') : '${t.title} ${CesarText.categoryName(t.category, repository.budgets)}',
      direction: t == null ? null : (t.type == TransactionType.income ? 'income' : (t.type == TransactionType.expense ? 'expense' : 'transfer')),
      category: t?.category,
      isRecord: t != null,
    );
    final fresh = engine.parse(text);
    final tx = const {'expense', 'income', 'transfer'}.contains(fresh.intent);
    return PendingReplyCheck.classify(text, subject,
        textDirection: tx ? fresh.intent : null, textCategory: tx ? fresh.category : null, commands: true, now: _clock());
  }

  AssistantReply? _answerPending(_Pending pending, String text) {
    final s = CesarText.simplify(text);
    const waitsForWords = {_PendingKind.awaitChanges, _PendingKind.chooseTarget, _PendingKind.offerSuggestion, _PendingKind.correctionOrNew};
    if (waitsForWords.contains(pending.kind) && !_isYes(s) && !_isNo(s) && _shiftFrom(pending, text) != TopicShift.none) {
      _pending = null;
      final cmd = pending.command;
      if (cmd != null && cmd.kind == ChatCommandKind.delete) _notice = 'Não apaguei nada.';
      if (pending.kind == _PendingKind.correctionOrNew) _notice = 'Não mudei nem registrei aquele lançamento.';
      return null;
    }
    switch (pending.kind) {
      case _PendingKind.confirmDelete:
        if (_isYes(s)) {
          _pending = null;
          return _delete(pending.targets);
        }
        _pending = null;
        if (_isNo(s)) return const AssistantReply('Tudo bem, não apaguei nada. 👍', route: 'delete_canceled');
        _notice = 'Não apaguei nada.';
        return null;
      case _PendingKind.confirmGoalDelete:
        _pending = null;
        if (_isYes(s)) {
          final g = pending.goal!;
          repository.deleteGoal(g.id);
          history.push(ChatAction.custom((r) {
            if (r.goals.any((x) => x.id == g.id)) return false;
            r.addGoal(g);
            return true;
          }, 'A meta "${g.title}" está de volta.'));
          _lastMutationTurn = _turn;
          return AssistantReply('Pronto, apaguei a meta "${g.title}". Se foi engano, diga "desfaz". 🗑️', route: 'goal_deleted');
        }
        if (_isNo(s)) return const AssistantReply('Tudo bem, a meta continua lá. 👍', route: 'delete_canceled');
        _notice = 'Não apaguei a meta.';
        return null;
      case _PendingKind.confirmCategoryDelete:
        _pending = null;
        if (_isYes(s)) return _deleteCategory(pending.category!);
        if (_isNo(s)) return const AssistantReply('Tudo bem, a categoria continua lá. 👍', route: 'delete_canceled');
        _notice = 'Não apaguei a categoria.';
        return null;
      case _PendingKind.chooseTarget:
        if (_isNo(s)) {
          _pending = null;
          return const AssistantReply('Tudo bem, deixei tudo como estava. 👍', route: 'choose_canceled');
        }
        final picked = _pick(pending.targets, s);
        if (picked == null && _triedToPick(pending.targets, s)) {
          // "4" with 3 options, or "o de 50" when all three are 50: still
          // choosing — ask again instead of dropping the list and reading the
          // answer as a new entry (R2-CHAOS-017/026).
          final n = pending.targets.length;
          final list = [for (var i = 0; i < n; i++) '${i + 1}. ${CesarText.describe(pending.targets[i], _clock())}'].join('\n');
          final why = RegExp(r'\d+$').hasMatch(s) && s.split(' ').length <= 2 ? 'Só há $n opções.' : 'Mais de um lançamento combina com isso.';
          return AssistantReply('$why Qual deles? Responda com o número de 1 a $n (ou "nenhum").\n$list', route: 'choose');
        }
        _pending = null;
        if (picked == null) {
          _notice = pending.command?.kind == ChatCommandKind.delete ? 'Não apaguei nada.' : null;
          return null;
        }
        final cmd = pending.command!;
        return _act(cmd, [picked], text);
      case _PendingKind.offerSuggestion:
        _pending = null;
        if (_isNo(s)) return const AssistantReply('Tudo bem, deixei tudo como estava. 👍', route: 'choose_canceled');
        final offered = _existing(pending.targets.map((t) => t.id).toList());
        if (offered.length > 1 && _acceptsOffer(s)) {
          // "sim" to several suggestions: which one? (CHAOS-B-025)
          _pending = _Pending(_PendingKind.chooseTarget, offered, pending.command);
          final now = _clock();
          final list = [for (var i = 0; i < offered.length; i++) '${i + 1}. ${CesarText.describe(offered[i], now)}'].join('\n');
          return AssistantReply('Qual deles?\n$list\n\nResponda com o número (ou "nenhum").',
              spokenText: 'Qual deles? ${[for (var i = 0; i < offered.length; i++) 'Opção ${i + 1}: ${offered[i].title}'].join('. ')}.',
              route: 'choose');
        }
        final chosen = offered.length == 1 && _acceptsOffer(s) ? offered.first : (offered.isEmpty ? null : _pick(offered, s));
        // Anything else is a new message, read as usual.
        if (chosen == null) return null;
        return _act(pending.command!, [chosen], text);
      case _PendingKind.correctionOrNew:
        _pending = null;
        final cmd = pending.command!;
        if (_saysNew.hasMatch(s)) return AssistantReply('', route: 'new_entry', rewrittenInput: cmd.entryText);
        if (_saysCorrection.hasMatch(s) || _isYes(s)) {
          final targets = _existing(pending.targets.map((t) => t.id).toList());
          if (targets.isEmpty) return AssistantReply('', route: 'new_entry', rewrittenInput: cmd.entryText);
          return _act(cmd, targets, text);
        }
        if (_isNo(s)) return const AssistantReply('Tudo bem, não mudei nem registrei nada. 👍', route: 'edit_canceled');
        _notice = 'Não mudei nem registrei aquele lançamento.';
        return null;
      case _PendingKind.awaitChanges:
        _pending = null;
        if (_isNo(s)) return const AssistantReply('Tudo bem, deixei como estava. 👍', route: 'edit_canceled');
        final cmd = TransactionCommandParser.parse(text, now: _clock(), budgets: repository.budgets);
        final changes = cmd != null && cmd.kind == ChatCommandKind.edit && cmd.reference.isEmpty
            ? cmd.changes
            : TransactionCommandParser.parseChanges(text, now: _clock(), budgets: repository.budgets);
        // A bare title ("renomeia pra Padaria" was already handled above).
        if (changes.isEmpty) return null;
        return _applyEdit(pending.targets, changes, text);
    }
  }

  /// Whether [s] is an (unsuccessful) attempt to choose among [options] — a
  /// bare number, or a short reference ("o de 50") matching several — rather
  /// than a new message. A new command or entry is never a pick.
  bool _triedToPick(List<FinancialTransaction> options, String s) {
    if (RegExp(r'^(?:o\s+|a\s+|opcao\s+|numero\s+)?\d{1,3}$').hasMatch(s)) return true;
    if (s.split(' ').length > 5 || TransactionCommandParser.looksLikeFullEntry(s)) return false;
    if (RegExp('^(?:${TransactionCommandParser.deleteVerbs}|muda|altera|troca|corrige|desfaz)\\b').hasMatch(s)) return false;
    if (!RegExp(r'^(?:o|a|os|as|aquele|aquela)\b').hasMatch(s)) return false;
    final spec = TransactionReferenceResolver.parse(s, now: _clock());
    if (spec.amount == null && spec.dayStart == null && spec.terms.isEmpty) return false;
    final r = TransactionReferenceResolver.resolve(spec, all: options, recentGroups: const [], budgets: repository.budgets);
    return r.matches.length > 1;
  }

  /// Which option the user chose: "2", "o segundo", "o de 48", "o de ontem", "o último".
  FinancialTransaction? _pick(List<FinancialTransaction> options, String s) {
    const ordinals = {'primeiro': 1, 'primeira': 1, 'segundo': 2, 'segunda': 2, 'terceiro': 3, 'terceira': 3, 'quarto': 4, 'quarta': 4, 'quinto': 5, 'quinta': 5};
    final n = RegExp(r'^(?:o\s+|a\s+|opcao\s+|numero\s+|n\s+)?(\d)(?:\s*[oa]|\s+opcao)?$').firstMatch(s);
    if (n != null) {
      final i = int.parse(n.group(1)!);
      return i >= 1 && i <= options.length ? options[i - 1] : null;
    }
    final o = RegExp(r'^(?:o\s+|a\s+)?(primeir[oa]|segund[oa]|terceir[oa]|quart[oa]|quint[oa])(?:\s+(?:opcao|lancamento))?$').firstMatch(s);
    if (o != null) {
      final i = ordinals[o.group(1)!]!;
      return i <= options.length ? options[i - 1] : null;
    }
    if (RegExp(r'^(?:o\s+|a\s+)?ultim[oa]$').hasMatch(s)) return options.last;
    // "o de 48", "o de ontem", "o do carrefour"
    if (s.split(' ').length <= 5) {
      final spec = TransactionReferenceResolver.parse(s, now: _clock());
      if (spec.amount != null || spec.dayStart != null || spec.terms.isNotEmpty) {
        final r = TransactionReferenceResolver.resolve(spec, all: options, recentGroups: const [], budgets: repository.budgets);
        if (r.matches.length == 1) return r.matches.first;
      }
    }
    return null;
  }

  AssistantReply _delete(List<FinancialTransaction> targets) {
    final now = _clock();
    for (final t in targets) {
      repository.deleteTransaction(t.id);
    }
    history.push(ChatAction(ChatActionKind.deleted, targets));
    final ids = targets.map((t) => t.id).toSet();
    _forget(ids);
    _lastMutationTurn = _turn;
    final what = targets.length == 1
        ? CesarText.describe(targets.first, now)
        : '${targets.length} lançamentos (${CesarText.money(targets.fold(0.0, (a, t) => a + t.amount))})';
    return AssistantReply('Pronto, apaguei $what. 🗑️ Se foi engano, é só dizer "desfaz".',
        spokenText: 'Pronto, apaguei $what. Se foi engano, diga desfaz.', route: 'deleted', removedIds: ids);
  }

  void _forget(Set<String> ids) {
    for (final g in _groups) {
      g.removeWhere(ids.contains);
    }
    _groups.removeWhere((g) => g.isEmpty);
    if (_focus.any(ids.contains)) {
      _focus = const [];
      _focusDeleted = true;
    }
  }

  AssistantReply _undo() {
    final result = history.undo(repository, now: _clock());
    if (result == null) {
      if (history.droppedOlder) {
        return const AssistantReply(
            'Já desfiz tudo o que eu consigo: guardo só as últimas ${ChatActionHistory.maxActions} ações desta conversa. '
            'Para os lançamentos mais antigos, diga qual apagar — ex.: "apaga o uber de ontem".',
            route: 'undo_limit');
      }
      return const AssistantReply('Não tenho nada meu para desfazer nesta conversa. Se quiser apagar algum lançamento, diga qual — ex.: "apaga o uber de ontem".',
          route: 'undo_empty');
    }
    _pending = null;
    if (!result.undone) return AssistantReply(result.message, route: 'undo_failed');
    if (result.removedIds.isNotEmpty) _forget(result.removedIds);
    if (result.action.kind == ChatActionKind.deleted) {
      final ids = result.restoredIds.toList();
      _groups.add(ids);
      _focus = List.unmodifiable(ids);
      _focusDeleted = false;
    }
    _lastMutationTurn = _turn;
    return AssistantReply(result.message, route: 'undo', removedIds: result.removedIds, changedIds: result.restoredIds);
  }

  // ───────────────────────── goals ─────────────────────────

  String _goalLine(FinancialGoal g) {
    final pct = (g.progress * 100).round();
    return '"${g.title}" tem ${CesarText.money(g.savedAmount)} de ${CesarText.money(g.targetAmount)} ($pct%)';
  }

  /// Null when the phrase didn't name the word "meta" nor an existing goal —
  /// then it is an ordinary entry ("coloquei 50 no carro").
  AssistantReply? _runGoalCommand(GoalCommand c) {
    final pool = c.kind == GoalCommandKind.delete ? repository.goals : repository.goals.where((g) => !g.isCompleted).toList();
    List<FinancialGoal> matches;
    if (c.goalTerm.isEmpty) {
      if (!c.saidMeta) return null;
      matches = pool;
    } else {
      final t = CesarText.fold(c.goalTerm);
      matches = pool.where((g) {
        final title = CesarText.fold(g.title);
        return title.contains(t) || t.contains(title);
      }).toList();
    }
    if (matches.isEmpty) {
      if (!c.saidMeta) return null;
      if (repository.goals.isEmpty) {
        return const AssistantReply('Você ainda não tem metas. Para criar: "quero juntar 5000 para uma viagem até dezembro".', route: 'goal_not_found');
      }
      return AssistantReply('Não achei a meta "${c.goalTerm}". Suas metas: ${repository.goals.map((g) => '"${g.title}"').join(', ')}.', route: 'goal_not_found');
    }
    if (matches.length > 1) {
      return AssistantReply('Qual meta? ${matches.map((g) => '"${g.title}"').join(', ')}. Diga, por exemplo, "guardei 100 na ${matches.first.title.toLowerCase()}".',
          route: 'goal_choose');
    }
    final goal = matches.first;
    switch (c.kind) {
      case GoalCommandKind.contribute:
        final updated = repository.contributeToGoal(goal.id, c.amount!);
        history.push(ChatAction.custom((r) => _goalExists(r, goal.id) && r.withdrawFromGoal(goal.id, c.amount!).id == goal.id, 'Tirei ${CesarText.money(c.amount!)} da meta "${goal.title}".'));
        _lastMutationTurn = _turn;
        if (updated.isCompleted) {
          return AssistantReply('Parabéns! 🎉 Você bateu a meta "${updated.title}": ${CesarText.money(updated.savedAmount)} guardados!', route: 'goal_contrib');
        }
        return AssistantReply('Anotado! Guardei ${CesarText.money(c.amount!)} na meta: ${_goalLine(updated)} — faltam ${CesarText.money(updated.remaining)}. 🎯',
            route: 'goal_contrib');
      case GoalCommandKind.withdraw:
        final updated = repository.withdrawFromGoal(goal.id, c.amount!);
        final taken = goal.savedAmount - updated.savedAmount;
        history.push(ChatAction.custom((r) => _goalExists(r, goal.id) && r.contributeToGoal(goal.id, taken).id == goal.id, 'Devolvi ${CesarText.money(taken)} para a meta "${goal.title}".'));
        _lastMutationTurn = _turn;
        final capped = taken < c.amount! - 0.001 ? ' (só havia ${CesarText.money(taken)} guardados)' : '';
        return AssistantReply('Pronto, tirei ${CesarText.money(taken)} da meta$capped. Agora ${_goalLine(updated)}.', route: 'goal_withdraw');
      case GoalCommandKind.delete:
        _pending = _Pending(_PendingKind.confirmGoalDelete, const [], null, null, goal);
        return AssistantReply('Vou apagar a meta ${_goalLine(goal)}. Confirma? (sim/não)', route: 'confirm_delete');
    }
  }

  // ───────────────────────── "mais 20 de gorjeta", "repete o último" ─────────────────────────

  static const _paymentWords = {
    'pix': 'no pix',
    'debit_card': 'no débito',
    'credit_card': 'no crédito',
    'cash': 'em dinheiro',
    'bank_slip': 'no boleto',
  };

  String _uniqueId() {
    var n = _clock().microsecondsSinceEpoch;
    final ids = repository.transactions.map((t) => t.id).toSet();
    while (ids.contains('chat-$n')) {
      n++;
    }
    return 'chat-$n';
  }

  /// Entries that only make sense next to the last one: "mais 20 de gorjeta"
  /// (a linked expense with the same payment), "e 30 na padaria" (rewritten
  /// as a full entry inheriting the payment), "repete o último".
  AssistantReply? _followUpEntry(String text) {
    if (_turn - _lastMutationTurn > 3) return null;
    final targets = _lastTargets();
    if (targets.isEmpty) return null;
    final last = targets.first;
    final s = CesarText.simplify(text);
    final now = _clock();

    if (RegExp(r'^(?:(?:repete|repita|repetir|lanca|registra)(?:\s+(?:o\s+|a\s+)?(?:ultimo|ultima|mesmo|mesma|isso|esse|essa|de\s+novo|igual))*|de\s+novo|'
            r'(?:mais\s+)?(?:um|uma|outro|outra)\s+(?:igual|desse|dessa|mesmo|mesma|daquele)|mais\s+um(?:a)?\s+igual)$')
        .hasMatch(s)) {
      final copy = FinancialTransaction(
        id: _uniqueId(),
        title: last.title,
        amount: last.amount,
        type: last.type,
        category: last.category,
        paymentMethod: last.paymentMethod,
        date: now,
        installments: last.installments,
        currentInstallment: last.installments == null ? null : 1,
      );
      repository.addTransaction(copy);
      recordCreated([copy.id]);
      return AssistantReply('Registrei de novo: **${CesarText.describe(copy, now)}**. Se não era isso, diga "desfaz". 🔁', route: 'saved');
    }

    const num = r'(?:r\$\s*)?(\d{1,3}(?:\.\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?:\s*(?:reais|real|conto|contos|pila))?';
    final more = RegExp('^(?:e\\s+)?mais\\s+$num(?:\\s+(?:de|do|da|no|na|em|com|pro|pra|pela|pelo)\\s+(.+))?\$').firstMatch(s);
    if (more != null) {
      final amount = LocalFinancialNlpEngine.cleanAndParseAmount(more.group(1));
      if (amount == null || amount <= 0) return null;
      final what = more.group(2)?.trim() ?? '';
      final category = what.isEmpty ? last.category : (CesarText.resolveCategory(what, repository.budgets) ?? last.category);
      final title = what.isEmpty ? '${last.title} (adicional)' : what[0].toUpperCase() + what.substring(1);
      final tx = FinancialTransaction(
        id: _uniqueId(),
        title: title,
        amount: amount,
        type: last.type,
        category: category,
        paymentMethod: last.paymentMethod,
        date: last.date,
      );
      repository.addTransaction(tx);
      recordCreated([tx.id]);
      return AssistantReply(
          'Anotei mais ${CesarText.money(amount)} de $title (${CesarText.paymentName(last.paymentMethod)}), junto de ${last.title}. '
          'Se era para somar ao mesmo lançamento, diga "desfaz" e depois "muda pra ${(last.amount + amount).toStringAsFixed(0)}". ➕',
          route: 'saved');
    }

    final andAlso = RegExp('^e\\s+(?:tambem\\s+)?$num\\s+(no|na|em|de|do|da|com|pro|pra)\\s+(.+)\$').firstMatch(s);
    if (andAlso != null && !RegExp(r'\b(?:pix|debito|credito|dinheiro|boleto|cartao)\b').hasMatch(andAlso.group(3)!)) {
      const verbs = {TransactionType.income: 'recebi', TransactionType.transfer: 'transferi', TransactionType.expense: 'gastei'};
      final pay = _paymentWords[last.paymentMethod] ?? '';
      final day = CesarText.relativeDay(last.date, now);
      final when = day == 'ontem' || day == 'anteontem' ? ' $day' : '';
      return AssistantReply('', route: 'rewrite',
          rewrittenInput: '${verbs[last.type]} ${andAlso.group(1)} ${andAlso.group(2)} ${andAlso.group(3)} $pay$when'.trim());
    }
    return null;
  }

  // ───────────────────────── "o mesmo de ontem" ─────────────────────────

  static final RegExp _sameAsPattern = RegExp(
    r'\b(?:o\s+)?mesmo(?:\s+valor)?\s+(?:de|que|do|da)\s+(?:(?:o\s+|a\s+)?de\s+)?'
    r'(ontem|anteontem|semana\s+passada|segunda|ter[cç]a|quarta|quinta|sexta|s[aá]bado|domingo)(?:\s+passad[oa])?\b'
    r'|\bigual\s+(?:a\s+|ao\s+|a\s+de\s+|ao\s+de\s+|de\s+)?'
    r'(ontem|anteontem|semana\s+passada|segunda|ter[cç]a|quarta|quinta|sexta|s[aá]bado|domingo)(?:\s+passad[oa])?\b',
  );

  /// "gastei o mesmo de ontem no almoço": copies the value, payment and
  /// category of the similar entry from that day into a new entry today and
  /// says what it copied. With nothing (or more than one thing) to copy from,
  /// the sentence goes on without the "o mesmo de ontem" — César asks the
  /// value instead of inventing it, and says why.
  AssistantReply? _sameAsBefore(String text) {
    final s = CesarText.simplify(text);
    final m = _sameAsPattern.firstMatch(s);
    if (m == null) return null;
    // Money going in ("recebi o mesmo de ontem") or a question is not this.
    if (RegExp(r'^(?:quanto|qual|quais|quando|recebi|ganhei|caiu)\b').hasMatch(s)) return null;
    final when = (m.group(1) ?? m.group(2))!;
    final rest = s.replaceFirst(m.group(0)!, ' ').replaceAll(RegExp(r'\b(?:gastei|paguei|comprei|foi|deu|tambem|hoje)\b'), ' ');
    final item = rest.replaceAll(RegExp(r'\s+'), ' ').trim();

    final spec = TransactionReferenceResolver.parse('$item $when', now: _clock());
    final found = TransactionReferenceResolver.resolve(
      ReferenceSpec(terms: spec.terms, dayStart: spec.dayStart, dayEnd: spec.dayEnd, dateLabel: spec.dateLabel, type: TransactionType.expense),
      all: repository.transactions,
      recentGroups: const [],
      budgets: repository.budgets,
    ).matches;

    if (found.length != 1) {
      _notice = found.isEmpty
          ? 'Não achei um lançamento parecido ${spec.dateLabel ?? when} para copiar o valor.'
          : 'Achei ${found.length} lançamentos ${spec.dateLabel ?? when} e não sei qual copiar.';
      // Rebuilt from the original words (accents kept) so the entry is named
      // "Almoço", not "almoco".
      final original = text.toLowerCase();
      final withoutReference = original.replaceFirst(_sameAsPattern, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      return AssistantReply('', route: 'rewrite', rewrittenInput: withoutReference.isEmpty ? 'gastei' : withoutReference);
    }

    final source = found.first;
    final now = _clock();
    final copy = FinancialTransaction(
      id: _uniqueId(),
      title: source.title,
      amount: source.amount,
      type: source.type,
      category: source.category,
      paymentMethod: source.paymentMethod,
      date: now,
    );
    repository.addTransaction(copy);
    recordCreated([copy.id]);
    final from = CesarText.relativeDay(source.date, now);
    final msg = 'Copiei do lançamento de $from: **${source.title}**, ${CesarText.money(source.amount)} '
        '(${CesarText.paymentName(source.paymentMethod)}). Registrei hoje com o mesmo valor e a mesma forma de pagamento. '
        'Se não era isso, diga "desfaz". 🔁';
    return AssistantReply(msg, spokenText: msg.replaceAll('**', '').replaceAll(' 🔁', ''), route: 'saved');
  }

  // ───────────────────────── categories & budgets ─────────────────────────

  BudgetCategory? _budgetNamed(String name) {
    final custom = repository.findCustomCategoryCode(name);
    final code = custom ?? CesarText.resolveCategory(name, repository.budgets);
    if (code == null) return null;
    return repository.budgets.where((b) => b.category == code).firstOrNull;
  }

  AssistantReply _runCategoryCommand(CategoryCommand c) {
    switch (c.kind) {
      case CategoryCommandKind.create:
        final existing = repository.budgets.where((b) => CesarText.fold(b.name) == CesarText.fold(c.name)).firstOrNull;
        if (existing != null && (!existing.isCustom || c.limit == null)) {
          return AssistantReply('A categoria **${existing.name}** já existe. '
              '${c.limit == null ? 'Se quiser mudar o limite, diga "meu limite de ${existing.name.toLowerCase()} é 500".' : ''}'.trim(),
              route: 'category_exists');
        }
        if (existing != null) {
          // "cria a categoria pets com limite de 300" with Pets already there
          // only changes its limit (R2-CHAOS-007): say that, and make "desfaz"
          // put the old limit back instead of deleting the whole category.
          final oldLimit = existing.monthlyLimit;
          repository.setBudgetLimit(existing.category, c.limit!);
          history.push(ChatAction.custom((r) {
            if (!r.budgets.any((x) => x.category == existing.category)) return false;
            r.setBudgetLimit(existing.category, oldLimit);
            return true;
          }, 'O limite de ${existing.name} voltou a ser ${CesarText.money(oldLimit)}.'));
          _lastMutationTurn = _turn;
          return AssistantReply('A categoria **${existing.name}** já existia — mudei o limite de ${CesarText.money(oldLimit)} '
              'para ${CesarText.money(c.limit!)} por mês.', route: 'budget_set');
        }
        final created = repository.addBudgetCategory(c.name, c.limit ?? 0);
        history.push(ChatAction.custom((r) {
          if (!r.budgets.any((x) => x.category == created.category)) return false;
          r.removeBudgetCategory(created.category);
          return true;
        }, 'Removi a categoria ${created.name}.'));
        _lastMutationTurn = _turn;
        final limitText = c.limit != null && c.limit! > 0
            ? ' com limite de ${CesarText.money(c.limit!)} por mês'
            : '. Se quiser um limite mensal, diga "meu limite de ${created.name.toLowerCase()} é 300"';
        return AssistantReply('Pronto! Criei a categoria **${created.name}**$limitText. '
            'Agora é só falar, por exemplo, "gastei 50 em ${created.name.toLowerCase()}". 🗂️', route: 'category_created');

      case CategoryCommandKind.rename:
        final code = repository.findCustomCategoryCode(c.name);
        if (code == null) {
          final builtIn = _budgetNamed(c.name);
          return AssistantReply(
              builtIn != null
                  ? 'Só consigo renomear categorias criadas por você — ${builtIn.name} é uma categoria padrão do Krezio.'
                  : 'Não achei a categoria "${c.name}". Suas categorias: ${repository.budgets.map((b) => b.name).join(', ')}.',
              route: 'category_not_found');
        }
        final oldName = repository.budgets.firstWhere((b) => b.category == code).name;
        if (!repository.renameBudgetCategory(code, c.target!)) {
          return AssistantReply('Já existe uma categoria chamada "${c.target}". Escolha outro nome.', route: 'category_exists');
        }
        history.push(ChatAction.custom((r) => r.renameBudgetCategory(code, oldName), 'A categoria voltou a se chamar $oldName.'));
        _lastMutationTurn = _turn;
        return AssistantReply('Pronto! A categoria **$oldName** agora se chama **${c.target}**. Os lançamentos dela continuam lá. ✏️',
            route: 'category_renamed');

      case CategoryCommandKind.delete:
        final b = _budgetNamed(c.name);
        if (b == null) return AssistantReply('Não achei a categoria "${c.name}".', route: 'category_not_found');
        if (!b.isCustom) {
          return AssistantReply('${b.name} é uma categoria padrão do Krezio e não pode ser apagada. '
              'Se quiser, mude o limite: "meu limite de ${c.name} é 500".', route: 'category_protected');
        }
        final count = repository.transactions.where((t) => t.category == b.category).length;
        _pending = _Pending(_PendingKind.confirmCategoryDelete, const [], null, b);
        final note = count == 0 ? '' : ' Os $count lançamentos dela continuam salvos.';
        return AssistantReply('Vou apagar a categoria **${b.name}**.$note Confirma? (sim/não)', route: 'confirm_delete');

      case CategoryCommandKind.setLimit:
        final b = _budgetNamed(c.name);
        if (b == null) {
          return AssistantReply('Não tenho uma categoria "${c.name}" com orçamento. Quer criar? Diga "cria a categoria ${c.name} com limite de '
              '${c.limit!.toStringAsFixed(0)}".', route: 'category_not_found');
        }
        final old = b.monthlyLimit;
        repository.setBudgetLimit(b.category, c.limit!);
        history.push(ChatAction.custom((r) {
          if (!r.budgets.any((x) => x.category == b.category)) return false;
          r.setBudgetLimit(b.category, old);
          return true;
        }, 'O limite de ${b.name} voltou a ser ${CesarText.money(old)}.'));
        _lastMutationTurn = _turn;
        final now = repository.budgets.firstWhere((x) => x.category == b.category);
        final status = now.isOverBudget
            ? 'Você já gastou ${CesarText.money(now.currentSpent)} este mês — ${CesarText.money(now.currentSpent - now.monthlyLimit)} acima do novo limite.'
            : 'Você já usou ${CesarText.money(now.currentSpent)} este mês; sobram ${CesarText.money(now.remaining)}.';
        return AssistantReply('Pronto! O limite de **${b.name}** agora é ${CesarText.money(c.limit!)} por mês'
            '${old > 0 ? ' (antes: ${CesarText.money(old)})' : ''}. $status', route: 'budget_set');

      case CategoryCommandKind.moveAll:
        final from = _budgetNamed(c.name);
        final to = _budgetNamed(c.target!);
        if (from == null || to == null) {
          return AssistantReply('Não achei a categoria "${from == null ? c.name : c.target}".', route: 'category_not_found');
        }
        final moving = repository.transactions.where((t) => t.category == from.category).toList();
        if (moving.isEmpty) return AssistantReply('Não há lançamentos em ${from.name} para mover.', route: 'edit_noop');
        for (final t in moving) {
          repository.updateTransaction(t.copyWith(category: to.category));
        }
        history.push(ChatAction(ChatActionKind.edited, moving));
        _lastMutationTurn = _turn;
        return AssistantReply('Pronto! Movi ${moving.length} ${moving.length == 1 ? 'lançamento' : 'lançamentos'} de ${from.name} para ${to.name}. ✏️',
            route: 'edited', changedIds: moving.map((t) => t.id).toSet());
    }
  }

  static bool _goalExists(FinancialRepository r, String id) => r.goals.any((g) => g.id == id);

  AssistantReply _deleteCategory(BudgetCategory b) {
    repository.removeBudgetCategory(b.category);
    history.push(ChatAction.custom((r) {
      final restored = r.addBudgetCategory(b.name, b.monthlyLimit);
      if (restored.category != b.category) {
        for (final t in r.transactions.where((t) => t.category == b.category).toList()) {
          r.updateTransaction(t.copyWith(category: restored.category));
        }
      }
      return true;
    }, 'A categoria ${b.name} está de volta.'));
    _lastMutationTurn = _turn;
    return AssistantReply('Pronto, apaguei a categoria **${b.name}**. Se foi engano, diga "desfaz". 🗑️', route: 'category_deleted');
  }

  // ───────────────────────── editing ─────────────────────────

  static FinancialTransaction _rebuild(FinancialTransaction t, TransactionChanges c) {
    var type = c.type ?? t.type;
    var category = c.category ?? t.category;
    // A type switch without a category would leave an expense category on
    // an income ("Supermercado" as income) — use the neutral one instead.
    if (c.type != null && c.category == null && c.type != t.type) {
      const incomeCats = {'salary', 'income_other', 'investment'};
      if (type == TransactionType.income && !incomeCats.contains(t.category)) category = 'income_other';
      if (type != TransactionType.income && (t.category == 'salary' || t.category == 'income_other')) category = 'expense_other';
    }
    final payment = c.paymentMethod ?? t.paymentMethod;
    int? installments = c.installments ?? t.installments;
    if (payment != 'credit_card' || (installments ?? 1) <= 1) installments = null;
    final date = c.date == null ? t.date : DateTime(c.date!.year, c.date!.month, c.date!.day, t.date.hour, t.date.minute, t.date.second);
    return FinancialTransaction(
      id: t.id,
      title: c.title ?? t.title,
      amount: c.amount ?? t.amount,
      type: type,
      category: category,
      paymentMethod: payment,
      date: date,
      installments: installments,
      currentInstallment: installments == null ? null : (t.currentInstallment ?? 1),
      isRecurrent: t.isRecurrent,
      dueDay: t.dueDay,
      dueBusinessDay: t.dueBusinessDay,
      billingDay: t.billingDay,
      paymentMarginDays: t.paymentMarginDays,
      recurrenceDuration: t.recurrenceDuration,
      bankSource: t.bankSource,
      notes: t.notes,
    );
  }

  String _dayLabel(DateTime d) {
    final rel = CesarText.relativeDay(d, _clock());
    return rel.contains('/') ? rel : '$rel (${CesarText.ddmm(d)})';
  }

  /// "o valor de R$ 50,00 para R$ 45,00", one entry per changed field.
  List<String> _diff(FinancialTransaction a, FinancialTransaction b) {
    final out = <String>[];
    if ((a.amount - b.amount).abs() > 0.001) out.add('o valor de ${CesarText.money(a.amount)} para ${CesarText.money(b.amount)}');
    if (CesarText.dayOnly(a.date) != CesarText.dayOnly(b.date)) out.add('a data de ${_dayLabel(a.date)} para ${_dayLabel(b.date)}');
    if (a.type != b.type) out.add('o tipo de ${CesarText.typeName(a.type)} para ${CesarText.typeName(b.type)}');
    if (a.category != b.category) {
      out.add('a categoria de ${CesarText.categoryName(a.category, repository.budgets)} para ${CesarText.categoryName(b.category, repository.budgets)}');
    }
    if (a.paymentMethod != b.paymentMethod || a.installments != b.installments) {
      final inst = (b.installments ?? 1) > 1 ? ' em ${b.installments}x' : '';
      out.add('a forma de pagamento de ${CesarText.paymentName(a.paymentMethod)} para ${CesarText.paymentName(b.paymentMethod)}$inst');
    }
    if (a.title != b.title) out.add('o nome de "${a.title}" para "${b.title}"');
    return out;
  }

  static String _joinPt(List<String> parts) {
    if (parts.length <= 1) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')} e ${parts.last}';
  }

  AssistantReply _applyEdit(List<FinancialTransaction> targets, TransactionChanges changes, String text) {
    final updated = targets.map((t) => _rebuild(t, changes)).toList();
    final diffs = _diff(targets.first, updated.first);
    final now = _clock();
    if (diffs.isEmpty) {
      return AssistantReply('Esse lançamento já está assim: ${CesarText.describe(targets.first, now)}. Nada mudou.', route: 'edit_noop');
    }
    for (final t in updated) {
      repository.updateTransaction(t);
    }
    history.push(ChatAction(ChatActionKind.edited, targets));
    // Category memory: once corrected, similar entries get it right next time.
    if (changes.category != null && updated.first.category != targets.first.category) {
      repository.rememberCategoryOverride(targets.first.title, updated.first.category);
      if (updated.first.title != targets.first.title) repository.rememberCategoryOverride(updated.first.title, updated.first.category);
    }
    _focus = List.unmodifiable(updated.map((t) => t.id));
    _focusDeleted = false;
    _lastMutationTurn = _turn;

    const openers = ['Pronto!', 'Feito!', 'Certo!'];
    final opener = openers[CesarText.pick(text, openers.length)];
    final sentence = _joinPt(diffs);
    final where = targets.length == 1
        ? ' em **${updated.first.title}** (${CesarText.relativeDay(updated.first.date, now)})'
        : (targets.map((t) => t.title).toSet().length == 1
            ? ' nos ${targets.length} lançamentos de "${targets.first.title}"'
            : ' em ${_joinPt(targets.map((t) => '**${t.title}**').toList())}');
    final msg = '$opener Mudei $sentence$where. ✏️';
    return AssistantReply(msg, spokenText: msg.replaceAll('**', '').replaceAll(' ✏️', ''), route: 'edited', changedIds: updated.map((t) => t.id).toSet());
  }

  // ───────────────────────── questions ─────────────────────────

  /// Questions about the data, with follow-ups that reuse the last one ("e
  /// ontem?", "e com mercado?"). Null when [text] isn't a question.
  AssistantReply? handleQuestion(String text) {
    final talk = CesarSmallTalk.reply(text, now: _clock());
    if (talk != null) return AssistantReply(talk.text, spokenText: talk.spokenText, route: talk.kind == 'help' || talk.kind == 'howto' ? 'help' : 'smalltalk');

    final why = _explainCategory(text);
    if (why != null) return why;

    final whatIf = _hypothesis(text);
    if (whatIf != null) return whatIf;

    if (_lastQuery != null && _turn - _lastQaTurn <= 2) {
      final fq = FinancialQaEngine.parseFollowUp(text, _lastQuery!);
      if (fq != null) return _fromQa(_qa.answerQuery(fq, originalText: text));
    }
    final a = _qa.answer(text);
    if (a != null) return _fromQa(a);
    if (isUnansweredQuestion(text)) {
      return const AssistantReply(LocalFinancialNlpEngine.unansweredQuestionReply, route: 'unanswered');
    }
    return null;
  }

  /// "se eu comprar um celular de 2000 em 10x, quanto fica?", "e se eu
  /// gastar 300…?": a hypothesis is answered, never recorded (CONV-R3-003 /
  /// FEAT-R3-004). With an installment count César shows the monthly
  /// installment; otherwise the value goes to the affordability check. The
  /// full "what if" simulator is Item 3 of the plan.
  AssistantReply? _hypothesis(String text) => hypothesisReply(text);

  /// The answer to [text] when it is a hypothesis, or null. Public so the
  /// chat and the voice controller can check it *before* an answer is merged
  /// into a pending draft or batch: "e se fosse no pix?" with two entries
  /// waiting for the payment method saved both (CHAOS-A-003).
  AssistantReply? hypothesisReply(String text) {
    final h = HypothesisDetector.detect(text);
    if (h == null) return null;
    const note = 'É só uma simulação, então não registrei nada.';
    final amount = engine.parse(text).amount ?? engine.valueMentioned(text);
    if (h.isObligation) {
      // "tenho que pagar 380 de iptu", "falta pagar 640 do cartão": still to
      // happen — nothing recorded, and no "posso comprar?" about a bill.
      final value = amount != null && amount > 0 ? ' de ${CesarText.money(amount)}' : '';
      final msg = 'Entendi que isso$value ainda vai acontecer, então não registrei nada. '
          'Quando pagar (ou receber), é só me contar — ex.: "paguei${amount != null && amount > 0 ? ' ${amount.toStringAsFixed(0)}' : ''} no pix". '
          'Se quiser um aviso, diga "me lembra de pagar…".';
      return AssistantReply(msg, route: 'hypothesis');
    }
    if (amount != null && amount > 0 && h.isIncome) {
      // Money that would come in is not a purchase to check (ACC-A-018):
      // show what it does to the balance.
      final balance = repository.totalBalance;
      final after = balance + amount;
      return AssistantReply(
        '🧮 Se entrarem ${CesarText.money(amount)}, seu saldo iria de ${CesarText.money(balance)} para ${CesarText.money(after)}.\n\n'
        '$note Quando o dinheiro entrar, é só me contar (ex.: "recebi ${amount.toStringAsFixed(0)} no pix").',
        spokenText: 'Se entrarem ${CesarText.money(amount)}, seu saldo iria para ${CesarText.money(after)}. $note',
        route: 'hypothesis',
      );
    }
    if (amount == null || amount <= 0) {
      return const AssistantReply('$note Me diga o valor (ex.: "e se eu gastar 300 no mercado?") que eu faço a conta.',
          route: 'hypothesis');
    }
    final n = h.installments;
    if (n != null) {
      final per = amount / n;
      return AssistantReply(
        '🧮 ${CesarText.money(amount)} em ${n}x = $n × ${CesarText.money(per)} por mês.\n\n'
        '$note Se fizer a compra, é só me contar (ex.: "comprei … de ${amount.toStringAsFixed(0)} em ${n}x no crédito").',
        spokenText: '${CesarText.money(amount)} em $n vezes dá $n parcelas de ${CesarText.money(per)} por mês. $note',
        route: 'hypothesis',
      );
    }
    final check = AffordabilityAnalyzer(repository: repository).analyze('posso gastar ${amount.toStringAsFixed(2)} reais?');
    if (check == null) return AssistantReply('$note Seria um gasto de ${CesarText.money(amount)}.', route: 'hypothesis');
    return AssistantReply('$note\n\n${check.formattedText}', spokenText: '$note ${check.spokenText}', route: 'hypothesis');
  }

  /// A question must never become a draft entry ("o joão me deve quanto?"
  /// became a loan asking its value). A sentence asking something — a
  /// question mark or an interrogative word — with no past entry verb
  /// followed by a value gets the honest "ainda não sei" instead.
  static bool isUnansweredQuestion(String text) {
    final s = CesarText.simplify(text);
    if (s.split(' ').length < 2) return false;
    // "e ontem?" with no question to follow up is a fragment, not a question.
    if (RegExp(r'^(?:mas\s+)?e\s').hasMatch(s) && s.split(' ').length <= 3) return false;
    final asks = text.trim().endsWith('?') ||
        RegExp(r'\b(?:quanto|quantos|quantas|qual|quais|quando|onde|quem|cade|por\s*que|sera\s+que)\b').hasMatch(s) ||
        RegExp(r'^(?:como|o\s+que)\b').hasMatch(s);
    // "gastei 50 no mercado?" still tells an entry (with a doubt), and "uns
    // 50?" answers César's own question about a draft.
    return asks && !RegExp(r'\d').hasMatch(s);
  }

  /// "por que você colocou isso em lazer?" — says what decided the category
  /// of the last entry and how to fix it.
  AssistantReply? _explainCategory(String text) {
    final s = CesarText.simplify(text);
    if (!RegExp(r'^(?:mas\s+)?(?:por\s*que|pq|porque)\s+(?:(?:voce|vc|tu)\s+)?(?:colocou|botou|classificou|categorizou|pos|jogou|lancou|registrou)\b').hasMatch(s)) {
      return null;
    }
    final targets = _lastTargets();
    if (targets.isEmpty) {
      return const AssistantReply('Ainda não registrei nada nesta conversa. Quando eu lançar algo, posso te explicar a categoria.', route: 'explain');
    }
    final t = targets.first;
    final cat = CesarText.categoryName(t.category, repository.budgets);
    final learned = repository.recallCategoryOverride(t.title) == t.category;
    final reason = learned
        ? 'porque foi a categoria que você me ensinou para "${t.title}"'
        : 'pela descrição "${t.title}" — é onde esse tipo de gasto costuma entrar';
    return AssistantReply(
      'Coloquei **${t.title}** em $cat $reason. Se estiver errado, diga por exemplo "esse era lazer": eu corrijo e lembro nas próximas vezes.',
      route: 'explain',
    );
  }

  AssistantReply _fromQa(QaAnswer a) {
    _lastQuery = a.query;
    _lastQaTurn = _turn;
    return AssistantReply(a.text, spokenText: a.spokenText, route: a.route, chart: a.chart);
  }
}
