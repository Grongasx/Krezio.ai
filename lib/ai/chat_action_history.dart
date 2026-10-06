import '../backend/models/financial_transaction.dart';
import '../backend/repositories/financial_repository.dart';
import 'cesar_text.dart';

enum ChatActionKind { created, edited, deleted, custom }

/// One reversible thing César did to the records, with the snapshots needed
/// to put them back.
class ChatAction {
  final ChatActionKind kind;

  /// created/deleted: the records. edited: the records *before* the edit.
  final List<FinancialTransaction> records;

  /// [ChatActionKind.custom] (categories, budgets, goals): how to put it
  /// back — returning false when that is no longer possible (the goal or
  /// category was deleted/changed outside the chat) — and what to say once
  /// it's done.
  final bool Function(FinancialRepository repository)? revert;
  final String? undoMessage;

  const ChatAction(this.kind, this.records) : revert = null, undoMessage = null;

  const ChatAction.custom(bool Function(FinancialRepository repository) this.revert, String this.undoMessage, [this.records = const []])
      : kind = ChatActionKind.custom;
}

class UndoResult {
  final ChatAction action;
  final String message;

  /// Ids that no longer exist after the undo (an undone creation).
  final Set<String> removedIds;

  /// Ids that exist again or changed back.
  final Set<String> restoredIds;

  /// False when nothing could be reversed (and nothing was changed).
  final bool undone;

  const UndoResult(this.action, this.message, {this.removedIds = const {}, this.restoredIds = const {}, this.undone = true});
}

/// Short stack of what César did in this conversation — created, edited,
/// deleted — so "desfaz" / "volta atrás" reverses the last one, even a
/// deletion. Pure Dart; the repository is passed in to apply the undo.
class ChatActionHistory {
  static const int maxActions = 20;
  final List<ChatAction> _stack = [];

  /// Older actions dropped off the bottom of the stack (R2-CHAOS-024): when
  /// the stack runs out, César says there is a limit instead of "nothing to
  /// undo" while records he created are still there.
  bool _droppedOlder = false;
  bool get droppedOlder => _droppedOlder;

  bool get isEmpty => _stack.isEmpty;
  int get length => _stack.length;
  ChatAction? get last => _stack.isEmpty ? null : _stack.last;

  void push(ChatAction action) {
    if (action.records.isEmpty && action.kind != ChatActionKind.custom) return;
    _stack.add(action);
    if (_stack.length > maxActions) {
      _stack.removeAt(0);
      _droppedOlder = true;
    }
  }

  void clear() {
    _stack.clear();
    _droppedOlder = false;
  }

  /// Reverses the most recent action on [repository]. Null when there is
  /// nothing to undo. When the most recent action can't be reversed any more
  /// (its records/goal/category were deleted or changed on another screen),
  /// it says so and stops — it used to skip silently to the action before it
  /// and undo *that* instead (R2-CHAOS-014: "desfaz" removed the Mercado).
  UndoResult? undo(FinancialRepository repository, {DateTime? now}) {
    final today = now ?? DateTime.now();
    if (_stack.isEmpty) return null;
    final action = _stack.removeLast();
    final existing = {for (final t in repository.transactions) t.id: t};
    final names = _names(action.records, today);
    switch (action.kind) {
      case ChatActionKind.custom:
        var done = false;
        try {
          done = action.revert!(repository);
        } on ArgumentError {
          done = false;
        } on StateError {
          done = false;
        }
        if (!done) return UndoResult(action, gone, undone: false);
        return UndoResult(action, 'Desfeito! ${action.undoMessage} ↩️', restoredIds: action.records.map((t) => t.id).toSet());
      case ChatActionKind.created:
        final ids = action.records.map((t) => t.id).where(existing.containsKey).toSet();
        if (ids.isEmpty) return UndoResult(action, 'O lançamento que eu tinha registrado ($names) já foi apagado, então não havia nada para desfazer.', undone: false);
        for (final id in ids) {
          repository.deleteTransaction(id);
        }
        return UndoResult(action, 'Desfeito! Removi o lançamento que eu tinha registrado: $names. ↩️', removedIds: ids);
      case ChatActionKind.edited:
        final back = action.records.where((t) => existing.containsKey(t.id)).toList();
        if (back.isEmpty) return UndoResult(action, 'O lançamento que eu tinha alterado ($names) não existe mais, então não desfiz nada.', undone: false);
        for (final t in back) {
          repository.updateTransaction(t);
        }
        return UndoResult(action, 'Desfeito! Voltei $names para como estava antes. ↩️', restoredIds: back.map((t) => t.id).toSet());
      case ChatActionKind.deleted:
        final missing = action.records.where((t) => !existing.containsKey(t.id)).toList();
        if (missing.isEmpty) return UndoResult(action, '$names já ${action.records.length == 1 ? 'está' : 'estão'} de volta — não precisei desfazer nada.', undone: false);
        repository.restoreTransactions(missing);
        return UndoResult(action, 'Desfeito! $names ${missing.length == 1 ? 'está' : 'estão'} de volta. ↩️',
            restoredIds: missing.map((t) => t.id).toSet());
    }
  }

  /// Said when a custom revert is no longer possible.
  static const gone = 'Não consegui desfazer: o que eu tinha mudado (meta, categoria ou limite) foi apagado ou alterado fora do chat, '
      'então deixei tudo como está.';

  static String _names(List<FinancialTransaction> records, DateTime now) {
    if (records.length == 1) return CesarText.describe(records.first, now);
    if (records.length <= 3) return records.map((t) => CesarText.describe(t, now)).join(' e ');
    final total = records.fold(0.0, (a, t) => a + t.amount);
    return '${records.length} lançamentos (${CesarText.money(total)} no total)';
  }
}
