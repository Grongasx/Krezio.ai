import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/financial_transaction.dart';
import '../models/financial_reminder.dart';
import '../models/budget_category.dart';
import '../models/financial_goal.dart';
import '../repositories/financial_repository.dart';

/// Keeps a signed-in user's data mirrored in Firestore.
///
/// Krezio.ai stays offline-first: [FinancialRepository] keeps working purely
/// from its local on-device cache (see `PersistenceService`) with or without
/// a network connection. This service *additionally* pushes every change to
/// Firestore so it's backed up and available on other devices. Firestore's
/// own client-side persistence (enabled in `main.dart`) queues writes made
/// while offline and flushes them automatically once connectivity returns —
/// this service doesn't need to implement any of that retry/queue logic itself.
class CloudSyncService {
  final FinancialRepository repository;
  final String uid;
  final FirebaseFirestore _firestore;

  Timer? _debounce;
  void Function()? _listener;

  CloudSyncService({
    required this.repository,
    required this.uid,
    FirebaseFirestore? firestore,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  DocumentReference<Map<String, dynamic>> get _userDoc => _firestore.collection('users').doc(uid);

  /// Pulls this account's cloud snapshot into the repository. If the account
  /// has never synced before (e.g. first login after migrating from a
  /// local-only install), pushes the current local state up instead so the
  /// cloud isn't left empty.
  Future<void> pullFromCloud() async {
    final snapshot = await _userDoc.get();
    if (!snapshot.exists || snapshot.data() == null) {
      await pushToCloud();
      return;
    }

    final data = snapshot.data()!;
    repository.replaceAllFromCloud(
      transactions: _decodeList(data['transactions'], FinancialTransaction.fromJson),
      reminders: _decodeList(data['reminders'], FinancialReminder.fromJson),
      budgets: _decodeList(data['budgets'], BudgetCategory.fromJson),
      goals: _decodeList(data['goals'], FinancialGoal.fromJson),
      categoryOverrides: (data['categoryOverrides'] as Map<String, dynamic>? ?? {})
          .map((k, v) => MapEntry(k, v as String)),
    );
  }

  List<T> _decodeList<T>(dynamic raw, T Function(Map<String, dynamic>) fromJson) {
    if (raw is! List) return [];
    return raw.whereType<Map<String, dynamic>>().map(fromJson).toList();
  }

  /// Uploads the repository's current state as this account's cloud snapshot.
  Future<void> pushToCloud() async {
    await _userDoc.set({
      'transactions': repository.transactions.map((t) => t.toJson()).toList(),
      'reminders': repository.reminders.map((r) => r.toJson()).toList(),
      'budgets': repository.budgets.map((b) => b.toJson()).toList(),
      'goals': repository.goals.map((g) => g.toJson()).toList(),
      'categoryOverrides': repository.categoryOverrides,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Starts pushing to Firestore automatically whenever the repository
  /// changes (debounced so a burst of edits — like a multi-transaction split
  /// — only triggers one upload).
  void startAutoSync() {
    _listener = () {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 2), () {
        pushToCloud();
      });
    };
    repository.addListener(_listener!);
  }

  void dispose() {
    _debounce?.cancel();
    if (_listener != null) {
      repository.removeListener(_listener!);
    }
  }
}
