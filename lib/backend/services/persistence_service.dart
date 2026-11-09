import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/financial_transaction.dart';
import '../models/financial_reminder.dart';
import '../models/budget_category.dart';
import '../models/financial_goal.dart';
import '../models/financial_account.dart';

/// Persists the app's financial state to local device storage (via
/// shared_preferences — backed by localStorage on web, and native prefs on
/// mobile/desktop) so it survives an app restart or page reload.
///
/// Krezio.ai is a 100% on-device app: nothing here ever leaves the device.
class PersistenceService {
  const PersistenceService() : _scope = '';
  const PersistenceService.local() : _scope = 'krezio_v2_local_';

  PersistenceService.account(String uid)
      : _scope = 'krezio_v2_account_${base64Url.encode(utf8.encode(uid))}_';

  final String _scope;

  String _key(String legacyKey) => '$_scope$legacyKey';
  static const _kTransactions = 'krezio_transactions_v1';
  static const _kReminders = 'krezio_reminders_v1';
  static const _kBudgets = 'krezio_budgets_v1';
  static const _kGoals = 'krezio_goals_v1';
  static const _kCategoryOverrides = 'krezio_category_overrides_v1';
  static const _kAccounts = 'krezio_accounts_v1';
  static const _kPreferences = 'krezio_preferences_v1';
  static const _kHasSeeded = 'krezio_has_seeded_v1';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// True once the app has persisted data at least once — used to decide
  /// whether to load real data or seed the first-run demo dataset.
  Future<bool> hasPersistedData() async {
    final prefs = await _prefs;
    return prefs.getBool(_key(_kHasSeeded)) ?? false;
  }

  Future<void> markSeeded() async {
    final prefs = await _prefs;
    await prefs.setBool(_key(_kHasSeeded), true);
  }

  Future<void> saveTransactions(List<FinancialTransaction> items) async {
    final prefs = await _prefs;
    await prefs.setString(_key(_kTransactions), jsonEncode(items.map((t) => t.toJson()).toList()));
  }

  Future<List<FinancialTransaction>> loadTransactions() async {
    final prefs = await _prefs;
    final key = _key(_kTransactions);
    final raw = prefs.getString(key);
    if (raw == null) return [];
    final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    final transactions = list.map(FinancialTransaction.fromJson).toList();
    for (var i = 0; i < list.length; i++) {
      if (transactions[i].category == list[i]['category']) continue;
      await prefs.setString(key, jsonEncode(transactions.map((t) => t.toJson()).toList()));
      break;
    }
    return transactions;
  }

  Future<void> saveReminders(List<FinancialReminder> items) async {
    final prefs = await _prefs;
    await prefs.setString(_key(_kReminders), jsonEncode(items.map((r) => r.toJson()).toList()));
  }

  Future<List<FinancialReminder>> loadReminders() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_key(_kReminders));
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => FinancialReminder.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveBudgets(List<BudgetCategory> items) async {
    final prefs = await _prefs;
    await prefs.setString(_key(_kBudgets), jsonEncode(items.map((b) => b.toJson()).toList()));
  }

  Future<List<BudgetCategory>> loadBudgets() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_key(_kBudgets));
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => BudgetCategory.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveGoals(List<FinancialGoal> items) async {
    final prefs = await _prefs;
    await prefs.setString(_key(_kGoals), jsonEncode(items.map((g) => g.toJson()).toList()));
  }

  Future<List<FinancialGoal>> loadGoals() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_key(_kGoals));
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => FinancialGoal.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveCategoryOverrides(Map<String, String> overrides) async {
    final prefs = await _prefs;
    await prefs.setString(_key(_kCategoryOverrides), jsonEncode(overrides));
  }

  Future<Map<String, String>> loadCategoryOverrides() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_key(_kCategoryOverrides));
    if (raw == null) return {};
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(k, v as String));
  }

  Future<void> saveAccounts(List<FinancialAccount> items) async {
    final prefs = await _prefs;
    await prefs.setString(_key(_kAccounts), jsonEncode(items.map((a) => a.toJson()).toList()));
  }

  Future<List<FinancialAccount>> loadAccounts() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_key(_kAccounts));
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => FinancialAccount.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> savePreferences(Map<String, String> prefs) async {
    final p = await _prefs;
    await p.setString(_key(_kPreferences), jsonEncode(prefs));
  }

  Future<Map<String, String>> loadPreferences() async {
    final p = await _prefs;
    final raw = p.getString(_key(_kPreferences));
    if (raw == null) return {};
    return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, v.toString()));
  }

  /// Wipes only this namespace and records that it is intentionally empty.
  Future<void> clearAll() async {
    final prefs = await _prefs;
    final results = await Future.wait([
      prefs.remove(_key(_kTransactions)),
      prefs.remove(_key(_kReminders)),
      prefs.remove(_key(_kBudgets)),
      prefs.remove(_key(_kGoals)),
      prefs.remove(_key(_kCategoryOverrides)),
      prefs.remove(_key(_kAccounts)),
      prefs.remove(_key(_kPreferences)),
    ]);
    // An emptied app is real (empty) data, not a first run: removing this
    // flag made the next start seed the demo transactions again
    // (R2-CHAOS-010).
    final marked = await prefs.setBool(_key(_kHasSeeded), true);
    if (results.contains(false) || !marked) {
      throw StateError('Não foi possível apagar todos os dados neste aparelho.');
    }
  }
}
