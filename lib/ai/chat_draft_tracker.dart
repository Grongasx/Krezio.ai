/// Where a quick-reply chip of a chat card should act.
sealed class ChipTarget {
  const ChipTarget();
}

/// The card is the draft César is asking about right now: answer it.
class ChipOnActiveDraft extends ChipTarget {
  const ChipOnActiveDraft();
}

/// The card's draft was saved since: the chip edits those records.
class ChipOnSavedRecords extends ChipTarget {
  final List<String> transactionIds;
  const ChipOnSavedRecords(this.transactionIds);
}

/// The card's draft was left aside (a new subject came in) and never saved:
/// the chip brings it back and answers it.
class ChipOnStaleDraft extends ChipTarget {
  const ChipOnStaleDraft();
}

/// Gives every draft in the chat an identity that survives its follow-ups, so
/// a quick-reply chip acts on the card it was tapped on — not on whatever
/// draft happens to be pending now. Before, scrolling up and tapping "Pix" on
/// an older card answered the current draft instead. Pure Dart.
class ChatDraftTracker {
  int _seq = 0;
  String? _activeKey;
  final Map<String, List<String>> _savedByKey = {};

  /// The key of the draft César is asking about, or null.
  String? get activeKey => _activeKey;

  /// A brand-new draft started (not a follow-up of the current one).
  String startDraft() => _activeKey = 'draft-${++_seq}';

  /// The pending draft got an answer and is still pending: same identity.
  String continueDraft() => _activeKey ?? startDraft();

  /// The pending draft was saved as [transactionIds].
  void saved(List<String> transactionIds) {
    final key = _activeKey;
    if (key != null && transactionIds.isNotEmpty) _savedByKey[key] = List.unmodifiable(transactionIds);
    _activeKey = null;
  }

  /// The pending draft was dropped (cancelled or replaced by a new subject).
  void dropped() => _activeKey = null;

  /// Makes the draft of [key] the pending one again (a chip on a stale card).
  void reactivate(String key) => _activeKey = key;

  /// Records the draft of a card that was saved in one go (no question asked).
  void savedDirectly(String key, List<String> transactionIds) {
    if (transactionIds.isNotEmpty) _savedByKey[key] = List.unmodifiable(transactionIds);
  }

  /// Saved records of the card [key], if any.
  List<String>? savedIdsOf(String key) => _savedByKey[key];

  ChipTarget targetFor(String key) {
    if (key == _activeKey) return const ChipOnActiveDraft();
    final saved = _savedByKey[key];
    if (saved != null) return ChipOnSavedRecords(saved);
    return const ChipOnStaleDraft();
  }
}
