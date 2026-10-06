import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/financial_transaction.dart';
import '../models/financial_reminder.dart';
import '../models/budget_category.dart';
import '../models/financial_goal.dart';

/// Persists the app's financial state to local device storage (via
/// shared_preferences — backed by localStorage on web, and native prefs on
/// mobile/desktop) so it survives an app restart or page reload.
///
/// Krezio.ai is a 100% on-device app: nothing here ever leaves the device.
class PersistenceService {
  static const _kTransactions = 'krezio_transactions_v1';
  static const _kReminders = 'krezio_reminders_v1';
  static const _kBudgets = 'krezio_budgets_v1';
  static const _kGoals = 'krezio_goals_v1';
  static const _kCategoryOverrides = 'krezio_category_overrides_v1';
  static const _kHasSeeded = 'krezio_has_seeded_v1';

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  /// True once the app has persisted data at least once — used to decide
  /// whether to load real data or seed the first-run demo dataset.
  Future<bool> hasPersistedData() async {
    final prefs = await _prefs;
    return prefs.getBool(_kHasSeeded) ?? false;
  }

  Future<void> markSeeded() async {
    final prefs = await _prefs;
    await prefs.setBool(_kHasSeeded, true);
  }

  Future<void> saveTransactions(List<FinancialTransaction> items) async {
    final prefs = await _prefs;
    await prefs.setString(_kTransactions, jsonEncode(items.map((t) => t.toJson()).toList()));
  }

  Future<List<FinancialTransaction>> loadTransactions() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_kTransactions);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => FinancialTransaction.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveReminders(List<FinancialReminder> items) async {
    final prefs = await _prefs;
    await prefs.setString(_kReminders, jsonEncode(items.map((r) => r.toJson()).toList()));
  }

  Future<List<FinancialReminder>> loadReminders() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_kReminders);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => FinancialReminder.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveBudgets(List<BudgetCategory> items) async {
    final prefs = await _prefs;
    await prefs.setString(_kBudgets, jsonEncode(items.map((b) => b.toJson()).toList()));
  }

  Future<List<BudgetCategory>> loadBudgets() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_kBudgets);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => BudgetCategory.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveGoals(List<FinancialGoal> items) async {
    final prefs = await _prefs;
    await prefs.setString(_kGoals, jsonEncode(items.map((g) => g.toJson()).toList()));
  }

  Future<List<FinancialGoal>> loadGoals() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_kGoals);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => FinancialGoal.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveCategoryOverrides(Map<String, String> overrides) async {
    final prefs = await _prefs;
    await prefs.setString(_kCategoryOverrides, jsonEncode(overrides));
  }

  Future<Map<String, String>> loadCategoryOverrides() async {
    final prefs = await _prefs;
    final raw = prefs.getString(_kCategoryOverrides);
    if (raw == null) return {};
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(k, v as String));
  }

  /// Wipes all persisted app data (used by the "Limpar Histórico de Testes"
  /// action in Ajustes / Homologação).
  Future<void> clearAll() async {
    final prefs = await _prefs;
    await Future.wait([
      prefs.remove(_kTransactions),
      prefs.remove(_kReminders),
      prefs.remove(_kBudgets),
      prefs.remove(_kGoals),
      prefs.remove(_kCategoryOverrides),
    ]);
    // An emptied app is real (empty) data, not a first run: removing this
    // flag made the next start seed the demo transactions again
    // (R2-CHAOS-010).
    await prefs.setBool(_kHasSeeded, true);
  }
}
