import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/financial_transaction.dart';
import '../models/financial_reminder.dart';
import '../models/budget_category.dart';
import '../models/financial_goal.dart';
import '../models/financial_account.dart';
import '../repositories/financial_repository.dart';
import 'sync_merge.dart';

/// Keeps a signed-in user's data mirrored in Firestore.
///
/// Krezio.ai stays offline-first: [FinancialRepository] keeps working purely
/// from its local on-device cache (see `PersistenceService`) with or without a
/// network connection. This service *additionally* syncs every change with
/// `users/{uid}` so it's backed up and shared between devices. Firestore's own
/// client-side persistence (enabled in `main.dart`) queues writes made offline.
///
/// Each sync is a three-way merge per record ([SyncMerge]) inside a Firestore
/// transaction, against the snapshot both sides agreed on last time (the
/// "base", saved on the device). So two devices editing at once no longer
/// overwrite each other — before, the last one to push erased the other's edits.
/// Where the last agreed snapshot ("base") is kept on this device.
abstract class SyncBaseStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class _PrefsBaseStore implements SyncBaseStore {
  @override
  Future<String?> read(String key) async => (await SharedPreferences.getInstance()).getString(key);
  @override
  Future<void> write(String key, String value) async => (await SharedPreferences.getInstance()).setString(key, value);
}

class CloudSyncService {
  final FinancialRepository repository;
  final String uid;
  final FirebaseFirestore _firestore;
  final SyncBaseStore _store;

  Timer? _debounce;
  void Function()? _listener;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _remoteSub;
  Map<String, dynamic>? _base;
  bool _baseLoaded = false;
  bool _applying = false;
  Future<void>? _running;

  CloudSyncService({
    required this.repository,
    required this.uid,
    FirebaseFirestore? firestore,
    SyncBaseStore? baseStore,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _store = baseStore ?? _PrefsBaseStore();

  DocumentReference<Map<String, dynamic>> get _userDoc => _firestore.collection('users').doc(uid);
  String get _baseKey => 'krezio_cloud_sync_base_$uid';

  /// Kept for callers written before the merge existed: both now run [sync].
  Future<void> pullFromCloud() => sync();
  Future<void> pushToCloud() => sync();

  /// Merges this device with the cloud and applies the result to both sides.
  /// Calls made while one is running wait for it and then run once more.
  Future<void> sync() async {
    while (_running != null) {
      await _running;
    }
    final run = _syncOnce();
    _running = run;
    try {
      await run;
    } finally {
      _running = null;
    }
  }

  Future<void> _syncOnce() async {
    await _loadBase();
    final local = _localSnapshot();
    late Map<String, dynamic> merged;

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(_userDoc);
      final remote = snap.data();
      merged = remote == null ? local : _merge(_base, local, remote);
      if (remote == null || !_sameData(merged, remote)) {
        tx.set(_userDoc, {...merged, 'updatedAt': FieldValue.serverTimestamp()});
      }
    });

    if (!_sameData(merged, local)) _apply(merged);
    await _saveBase(merged);
  }

  /// Starts syncing automatically: local changes (debounced, so a burst of
  /// edits triggers one upload) and changes pushed by another device.
  void startAutoSync() {
    _listener = () {
      if (_applying) return;
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 2), () => sync());
    };
    repository.addListener(_listener!);

    _remoteSub = _userDoc.snapshots().listen((snap) {
      final data = snap.data();
      if (snap.metadata.hasPendingWrites || data == null) return; // our own write
      if (_base != null && _sameData(_strip(data), _base!)) return; // nothing new
      sync();
    });
  }

  void dispose() {
    _debounce?.cancel();
    _remoteSub?.cancel();
    if (_listener != null) repository.removeListener(_listener!);
  }

  // ── snapshot helpers ──────────────────────────────────────────────────────

  Map<String, dynamic> _localSnapshot() => {
        'transactions': repository.transactions.map((t) => t.toJson()).toList(),
        'reminders': repository.reminders.map((r) => r.toJson()).toList(),
        'budgets': repository.budgets.map((b) => b.toJson()).toList(),
        'goals': repository.goals.map((g) => g.toJson()).toList(),
        'accounts': repository.accounts.map((a) => a.toJson()).toList(),
        'categoryOverrides': Map<String, String>.from(repository.categoryOverrides),
      };

  Map<String, dynamic> _merge(Map<String, dynamic>? base, Map<String, dynamic> local, Map<String, dynamic> remote) {
    List<Map<String, dynamic>> list(Map<String, dynamic>? m, String k) =>
        ((m?[k] as List?) ?? const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    List<Map<String, dynamic>>? baseList(String k) => base == null ? null : list(base, k);
    Map<String, String> map(Map<String, dynamic>? m) =>
        ((m?['categoryOverrides'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), v.toString()));

    List<Map<String, dynamic>> byId(String k, String idKey) => SyncMerge.mergeById(
          base: baseList(k),
          local: list(local, k),
          remote: list(remote, k),
          idOf: (r) => r[idKey].toString(),
        );

    return {
      'transactions': byId('transactions', 'id'),
      'reminders': byId('reminders', 'id'),
      'budgets': byId('budgets', 'category'),
      'goals': byId('goals', 'id'),
      'accounts': byId('accounts', 'id'),
      'categoryOverrides': SyncMerge.mergeMap(base: base == null ? null : map(base), local: map(local), remote: map(remote)),
    };
  }

  void _apply(Map<String, dynamic> data) {
    List<T> decode<T>(String k, T Function(Map<String, dynamic>) fromJson) =>
        ((data[k] as List?) ?? const []).whereType<Map>().map((e) => fromJson(Map<String, dynamic>.from(e))).toList();
    _applying = true;
    try {
      repository.replaceAllFromCloud(
        transactions: decode('transactions', FinancialTransaction.fromJson),
        reminders: decode('reminders', FinancialReminder.fromJson),
        budgets: decode('budgets', BudgetCategory.fromJson),
        goals: decode('goals', FinancialGoal.fromJson),
        accounts: data['accounts'] == null ? null : decode('accounts', FinancialAccount.fromJson),
        categoryOverrides:
            ((data['categoryOverrides'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), v.toString())),
      );
    } finally {
      _applying = false;
    }
  }

  Map<String, dynamic> _strip(Map<String, dynamic> remote) => Map.of(remote)..remove('updatedAt');

  bool _sameData(Map<String, dynamic> a, Map<String, dynamic> b) => SyncMerge.sameJson(_strip(a), _strip(b));

  // ── base persistence ──────────────────────────────────────────────────────

  Future<void> _loadBase() async {
    if (_baseLoaded) return;
    _baseLoaded = true;
    final raw = await _store.read(_baseKey);
    if (raw != null) _base = Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<void> _saveBase(Map<String, dynamic> merged) async {
    _base = _strip(merged);
    await _store.write(_baseKey, jsonEncode(_base));
  }
}
