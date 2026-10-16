import 'dart:convert';

/// Three-way merge of one user's data between this device and the cloud.
///
/// Before, every sync wrote the whole `users/{uid}` document, so when two
/// devices (or two browser tabs) edited at the same time the last one to push
/// silently erased the other's changes. Now each record is merged on its own
/// against [base] — the snapshot both sides agreed on at the last sync:
///
/// - changed (or added, or deleted) on one side only → that change wins;
/// - changed on both sides → this device wins (it's the one being edited now);
/// - deleted on one side and changed on the other → the change wins (nothing
///   the user just edited disappears);
/// - with no base yet (first sync on this device) → union of both, local wins.
///
/// Pure Dart: records are JSON maps, so it's tested without Firestore.
class SyncMerge {
  SyncMerge._();

  /// Merges three lists of records identified by [idOf]. Order follows
  /// [local] first, then records that only exist remotely.
  static List<Map<String, dynamic>> mergeById({
    required List<Map<String, dynamic>>? base,
    required List<Map<String, dynamic>> local,
    required List<Map<String, dynamic>> remote,
    required String Function(Map<String, dynamic>) idOf,
  }) {
    final b = {for (final r in base ?? const <Map<String, dynamic>>[]) idOf(r): r};
    final l = {for (final r in local) idOf(r): r};
    final rm = {for (final r in remote) idOf(r): r};
    final ids = <String>[...l.keys, ...rm.keys.where((id) => !l.containsKey(id))];

    final out = <Map<String, dynamic>>[];
    for (final id in ids) {
      final picked = _pick(b[id], l[id], rm[id], hasBase: base != null);
      if (picked != null) out.add(picked);
    }
    return out;
  }

  /// Same rules for a map keyed by name (category overrides: "mercado do zé" → lazer).
  static Map<String, String> mergeMap({
    required Map<String, String>? base,
    required Map<String, String> local,
    required Map<String, String> remote,
  }) {
    final keys = {...local.keys, ...remote.keys};
    final out = <String, String>{};
    for (final k in keys) {
      final v = _pickValue(base?[k], local[k], remote[k], hasBase: base != null);
      if (v != null) out[k] = v;
    }
    return out;
  }

  static Map<String, dynamic>? _pick(
    Map<String, dynamic>? base,
    Map<String, dynamic>? local,
    Map<String, dynamic>? remote, {
    required bool hasBase,
  }) {
    if (!hasBase) return local ?? remote;
    final localChanged = !_same(base, local);
    final remoteChanged = !_same(base, remote);
    if (localChanged && local != null) return local; // local edit or add wins
    if (remoteChanged && remote != null) return remote; // remote edit or add
    if (localChanged && local == null) return remoteChanged ? remote : null; // local delete
    if (remoteChanged && remote == null) return null; // remote delete
    return local ?? remote;
  }

  static String? _pickValue(String? base, String? local, String? remote, {required bool hasBase}) {
    if (!hasBase) return local ?? remote;
    final localChanged = base != local;
    final remoteChanged = base != remote;
    if (localChanged && local != null) return local;
    if (remoteChanged && remote != null) return remote;
    if (localChanged && local == null) return remoteChanged ? remote : null;
    if (remoteChanged && remote == null) return null;
    return local ?? remote;
  }

  static bool _same(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (a == null || b == null) return a == b;
    return sameJson(a, b);
  }

  /// Whether two JSON values hold the same data, ignoring key order and
  /// whole numbers stored as doubles.
  static bool sameJson(Object? a, Object? b) => jsonEncode(_canon(a)) == jsonEncode(_canon(b));

  /// Firestore may hand keys back in another order (and ints as doubles), so
  /// compare a canonical form: sorted keys, whole doubles as ints.
  static Object? _canon(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      return {for (final k in keys) k: _canon(v[k])};
    }
    if (v is List) return v.map(_canon).toList();
    if (v is double && v.isFinite && v == v.truncateToDouble()) return v.toInt();
    return v;
  }
}
