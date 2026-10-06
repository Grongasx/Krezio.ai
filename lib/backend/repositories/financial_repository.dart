import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/financial_transaction.dart';
import '../models/budget_category.dart';
import '../models/financial_reminder.dart';
import '../models/financial_goal.dart';
import '../services/persistence_service.dart';
import '../../ai/local_nlp_engine.dart';
import '../../ai/category_name_matcher.dart';
import '../services/calendar_service.dart';

enum ProactiveAlertSeverity { info, warning, critical }

/// A proactive, unsolicited insight César surfaces on its own — a budget close to
/// or over its limit, a bill due soon, or an overdue debt — instead of only
/// answering when asked.
class ProactiveAlert {
  final String id;
  final String message;
  final ProactiveAlertSeverity severity;

  const ProactiveAlert({required this.id, required this.message, required this.severity});
}

/// Outcome of [FinancialRepository.applyDebtPayment]: the updated reminder, the income
/// transaction recorded for the amount received, and whether the debt is now settled.
class DebtPaymentResult {
  final FinancialReminder reminder;
  final FinancialTransaction transaction;
  final double amountPaid;
  final double remainingBalance;
  final bool isFullyPaid;

  /// What was owed before this payment.
  final double previousBalance;

  const DebtPaymentResult({
    required this.reminder,
    required this.transaction,
    required this.amountPaid,
    required this.remainingBalance,
    required this.isFullyPaid,
    this.previousBalance = 0,
  });

  /// How much more than the debt was paid ("recebi 300 do joão" when he owed
  /// 150 → 150). Zero when the payment was up to the balance.
  double get excess {
    final e = amountPaid - previousBalance;
    return e > 0.009 ? double.parse(e.toStringAsFixed(2)) : 0.0;
  }
}

class FinancialRepository extends ChangeNotifier {
  final List<FinancialTransaction> _transactions = [];
  final List<BudgetCategory> _budgets = [];
  final List<FinancialReminder> _reminders = [];
  final List<FinancialGoal> _goals = [];
  final Map<String, String> _categoryOverrides = {};
  final PersistenceService _persistence;
  bool _isInitialized = false;

  /// Every write goes through this chain so persistence operations always
  /// complete in the same order they were called, even though mutation
  /// methods fire-and-forget their `_persistAll()` call rather than awaiting
  /// it. Without this, an in-flight write from just before `clearAllData()`
  /// could resolve *after* the clear and resurrect the data it just wiped.
  Future<void> _pendingPersist = Future.value();

  /// Whether a write is queued on [_pendingPersist] and hasn't started yet.
  bool _persistQueued = false;

  /// Bumped whenever the whole dataset is swapped (clearAllData,
  /// replaceAllFromCloud). Anything holding on to records from before —
  /// César's undo stack, an in-flight initialize() — checks it and lets go
  /// (R2-CHAOS-011/012).
  int _dataGeneration = 0;
  int get dataGeneration => _dataGeneration;

  int _lastIssuedId = 0;

  /// A transaction id that is unique even when several are created in the
  /// same millisecond (a multi-transaction "50 no mercado e 30 na farmácia").
  /// Plain `millisecondsSinceEpoch` gave both the same id, so deleting or
  /// correcting one also hit the other. Still time-based and numeric.
  String _newId([String prefix = '']) {
    var id = DateTime.now().millisecondsSinceEpoch;
    if (id <= _lastIssuedId) id = _lastIssuedId + 1;
    while (_transactions.any((t) => t.id == '$prefix$id')) {
      id++;
    }
    _lastIssuedId = id;
    return '$prefix$id';
  }

  /// The constructor stays synchronous and always seeds the demo dataset — this
  /// keeps every existing test and any code that doesn't call [initialize]
  /// working exactly as before. [initialize] is what makes state durable: if
  /// persisted data exists it *replaces* this seed with the user's real data;
  /// if this is the first run, the seed itself becomes the persisted baseline.
  FinancialRepository({PersistenceService? persistence}) : _persistence = persistence ?? PersistenceService() {
    _initializeDefaultBudgets();
    _seedInitialData();
  }

  /// Loads persisted data from disk (overwriting the constructor's seed), or —
  /// on a genuine first run — persists the seed so it survives a restart. Must
  /// be awaited once at app startup before the UI reads from this repository;
  /// see `main.dart`. Safe to skip in tests that don't care about durability.
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;

    // Writes asked for while loading wait until the load is done: before,
    // an addTransaction() during initialize() wrote seed + new record over
    // the user's saved data before it was even read (R2-CHAOS-021).
    final loaded = Completer<void>();
    _pendingPersist = _pendingPersist.then((_) => loaded.future);
    final generation = _dataGeneration;
    final seedIds = _transactions.map((t) => t.id).toSet();

    try {
      final hasData = await _persistence.hasPersistedData();
      if (!hasData) {
        loaded.complete();
        await _persistAll(); // also marks seeded, now that there's something on disk
        return;
      }

      final results = await Future.wait([
        _persistence.loadTransactions(),
        _persistence.loadReminders(),
        _persistence.loadBudgets(),
        _persistence.loadGoals(),
        _persistence.loadCategoryOverrides(),
      ]);

      // A cloud snapshot or a "Limpar Histórico" landed while we were reading
      // the disk: it is newer than what we read — keep it, and save it
      // (R2-CHAOS-011: the cloud data was overwritten by the old local copy).
      if (_dataGeneration != generation) {
        loaded.complete();
        _persistAll();
        return;
      }

      // Records the user added while loading are kept on top of the saved ones.
      final addedMeanwhile = _transactions.where((t) => !seedIds.contains(t.id)).toList();

      _transactions
        ..clear()
        ..addAll(results[0] as List<FinancialTransaction>);
      for (final t in addedMeanwhile) {
        if (!_transactions.any((x) => x.id == t.id)) _transactions.insert(0, t);
      }
      _reminders
        ..clear()
        ..addAll(results[1] as List<FinancialReminder>);
      final loadedBudgets = results[2] as List<BudgetCategory>;
      if (loadedBudgets.isNotEmpty) {
        _budgets
          ..clear()
          ..addAll(loadedBudgets);
      }
      _goals
        ..clear()
        ..addAll(results[3] as List<FinancialGoal>);
      _categoryOverrides
        ..clear()
        ..addAll(results[4] as Map<String, String>);

      _recalculateBudgets();
      loaded.complete();
      if (addedMeanwhile.isNotEmpty) _persistAll();
      notifyListeners();
    } finally {
      if (!loaded.isCompleted) loaded.complete();
    }
  }

  /// Never lets a storage failure (private-browsing localStorage restrictions,
  /// a disk write error, or a test with no platform channel mocked) propagate
  /// out of a mutation — persistence is best-effort, not a correctness gate.
  /// Chained onto [_pendingPersist] so writes always land in call order — see
  /// its doc comment for why that matters.
  Future<void> _persistAll() {
    // A write already queued but not started will save the latest state
    // anyway (it reads the lists when it runs), so a burst of mutations
    // collapses into one write instead of re-serializing the whole history
    // once per mutation.
    if (_persistQueued) return _pendingPersist;
    _persistQueued = true;
    final next = _pendingPersist.then((_) async {
      // From here on, a new mutation needs a write of its own.
      _persistQueued = false;
      try {
        await Future.wait([
          _persistence.saveTransactions(_transactions),
          _persistence.saveReminders(_reminders),
          _persistence.saveBudgets(_budgets),
          _persistence.saveGoals(_goals),
          _persistence.saveCategoryOverrides(_categoryOverrides),
        ]);
        // Any real save — including the first one after clearAllData() wiped
        // the "seeded" flag — means there's now real data on disk. Without
        // this, work done in the same session as a "Limpar Histórico" would
        // silently be discarded and replaced by the demo seed on the next
        // app restart, since initialize() would still think this was a
        // brand-new install.
        await _persistence.markSeeded();
      } catch (_) {
        // Best-effort: in-memory state is still correct even if the save failed.
      }
    });
    _pendingPersist = next;
    return next;
  }

  /// Awaits any in-flight persistence writes. Mutation methods fire-and-forget
  /// their save so the UI never blocks on disk I/O; tests that simulate an app
  /// restart right after a mutation should await this first so the "restart"
  /// reads what was actually meant to be saved, not whatever had landed yet.
  @visibleForTesting
  Future<void> flushPendingWrites() => _pendingPersist;

  List<FinancialTransaction> get transactions => List.unmodifiable(_transactions);
  List<BudgetCategory> get budgets => List.unmodifiable(_budgets);
  List<FinancialReminder> get reminders => List.unmodifiable(_reminders);
  List<FinancialGoal> get goals => List.unmodifiable(_goals);
  Map<String, String> get categoryOverrides => Map.unmodifiable(_categoryOverrides);

  void _initializeDefaultBudgets() {
    _budgets.addAll([
      BudgetCategory(category: 'supermarket', name: 'Supermercado', monthlyLimit: 1200.0, currentSpent: 0.0, icon: BudgetCategory.getIconForCategory('supermarket'), color: BudgetCategory.getColorForCategory('supermarket')),
      BudgetCategory(category: 'leisure', name: 'Lazer & Alimentação', monthlyLimit: 600.0, currentSpent: 0.0, icon: BudgetCategory.getIconForCategory('leisure'), color: BudgetCategory.getColorForCategory('leisure')),
      BudgetCategory(category: 'transport', name: 'Transporte & Combustível', monthlyLimit: 450.0, currentSpent: 0.0, icon: BudgetCategory.getIconForCategory('transport'), color: BudgetCategory.getColorForCategory('transport')),
      BudgetCategory(category: 'housing', name: 'Moradia & Contas', monthlyLimit: 1800.0, currentSpent: 0.0, icon: BudgetCategory.getIconForCategory('housing'), color: BudgetCategory.getColorForCategory('housing')),
      BudgetCategory(category: 'health', name: 'Saúde & Farmácia', monthlyLimit: 300.0, currentSpent: 0.0, icon: BudgetCategory.getIconForCategory('health'), color: BudgetCategory.getColorForCategory('health')),
      BudgetCategory(category: 'education', name: 'Educação & Cursos', monthlyLimit: 400.0, currentSpent: 0.0, icon: BudgetCategory.getIconForCategory('education'), color: BudgetCategory.getColorForCategory('education')),
    ]);
  }

  void _seedInitialData() {
    final now = DateTime.now();
    _transactions.addAll([
      FinancialTransaction(
        id: 'init-1',
        title: 'Salário Mensal',
        amount: 4500.00,
        type: TransactionType.income,
        category: 'salary',
        paymentMethod: 'pix',
        date: DateTime(now.year, now.month, 5),
        bankSource: 'Banco Inter',
      ),
      FinancialTransaction(
        id: 'init-2',
        title: 'Supermercado Carrefour',
        amount: 380.50,
        type: TransactionType.expense,
        category: 'supermarket',
        paymentMethod: 'debit_card',
        date: DateTime(now.year, now.month, 10),
      ),
      FinancialTransaction(
        id: 'init-3',
        title: 'Aluguel do Apartamento',
        amount: 1400.00,
        type: TransactionType.expense,
        category: 'housing',
        paymentMethod: 'bank_slip',
        date: DateTime(now.year, now.month, 8),
        isRecurrent: true,
        dueDay: 8,
      ),
      FinancialTransaction(
        id: 'init-4',
        title: 'Academia SmartFit',
        amount: 119.90,
        type: TransactionType.expense,
        category: 'health',
        paymentMethod: 'credit_card',
        date: DateTime(now.year, now.month, 12),
        isRecurrent: true,
        dueDay: 12,
      ),
      FinancialTransaction(
        id: 'init-5',
        title: 'Uber Viagens',
        amount: 48.00,
        type: TransactionType.expense,
        category: 'transport',
        paymentMethod: 'pix',
        date: DateTime(now.year, now.month, 14),
      ),
    ]);

    final nextSalary = DateTime(now.year, now.month + 1, 5);
    _reminders.addAll([
      FinancialReminder(
        id: 'rem-seed-1',
        title: 'Receber Dividendos MXRF11',
        amount: 85.40,
        targetDate: DateTime(now.year, now.month, 15),
        type: ReminderType.dividend,
        notes: 'Previsão de proventos FII',
      ),
      FinancialReminder(
        id: 'rem-seed-2',
        title: 'Cobrar João (Empréstimo)',
        personName: 'João',
        amount: 150.00,
        targetDate: nextSalary,
        type: ReminderType.loanReceivable,
        notes: 'Prometeu acertar quando cair o salário dele',
      ),
    ]);

    _recalculateBudgets();
  }

  // ── MUTATIONS ──

  /// A money value that can be stored: finite and not negative. NaN/∞ used
  /// to be saved and turned the balance into NaN/−∞ (a typed "NaN" or
  /// "Infinity" parses as a double).
  static bool _isStorableAmount(double? v) => v != null && v.isFinite && v >= 0;

  /// A money amount a transaction can hold: at least one cent (R$ 0,001 used
  /// to be stored and shown as "R$ 0,00") and at most R$ 100 bilhões — the
  /// NLP engine already rejects anything above R$ 1 bilhão, and beyond this
  /// doubles stop keeping cents, so the balance math drifts.
  static bool _isMoneyAmount(double? v) => v != null && v.isFinite && v >= 0.01 && v <= 1e11;

  void addReminder(FinancialReminder reminder) {
    if (reminder.amount != null && !_isStorableAmount(reminder.amount)) return;
    _reminders.insert(0, reminder);
    _persistAll();
    notifyListeners();
  }

  void toggleReminderCompleted(String id) {
    final idx = _reminders.indexWhere((r) => r.id == id);
    if (idx != -1) {
      final rem = _reminders[idx];
      _reminders[idx] = rem.copyWith(isCompleted: !rem.isCompleted);
      _persistAll();
      notifyListeners();
    }
  }

  void removeReminder(String id) {
    _reminders.removeWhere((r) => r.id == id);
    _persistAll();
    notifyListeners();
  }

  /// Applies a payment against an existing debt reminder: reduces the outstanding
  /// [amountPaid] from its balance (marking it completed once the balance reaches
  /// zero or goes negative, i.e. an equal-or-over payment), and records the amount
  /// actually received as an income transaction so cash flow stays accurate.
  DebtPaymentResult applyDebtPayment(String reminderId, double amountPaid) {
    final idx = _reminders.indexWhere((r) => r.id == reminderId);
    if (idx == -1) {
      throw ArgumentError('Reminder not found: $reminderId');
    }
    // A zero/negative/NaN payment would record a R$ 0 or negative income and
    // *raise* the debt ("-50" made 150 become 200).
    if (!_isMoneyAmount(amountPaid)) {
      throw ArgumentError('Invalid payment amount: $amountPaid');
    }

    final reminder = _reminders[idx];
    // A debt already settled (or marked done by hand) can't be paid again —
    // it would record income against nothing (CHAOS-024). The chat only
    // offers open debts, so this guards direct callers.
    if (reminder.isCompleted) {
      throw StateError('Debt already settled: $reminderId');
    }
    final previousAmount = reminder.amount ?? 0.0;
    final remaining = previousAmount - amountPaid;
    final isFullyPaid = remaining <= 0.009;

    final updatedReminder = reminder.copyWith(
      amount: isFullyPaid ? 0.0 : remaining,
      isCompleted: isFullyPaid,
    );
    _reminders[idx] = updatedReminder;

    final personLabel = reminder.personName ?? reminder.title;
    final transaction = FinancialTransaction(
      id: _newId('debt-payment-'),
      title: 'Pagamento recebido de $personLabel',
      amount: amountPaid,
      type: TransactionType.income,
      category: 'income_other',
      paymentMethod: 'pix',
      date: DateTime.now(),
    );
    _transactions.insert(0, transaction);
    _recalculateBudgets();
    _persistAll();
    notifyListeners();

    return DebtPaymentResult(
      reminder: updatedReminder,
      transaction: transaction,
      amountPaid: amountPaid,
      remainingBalance: isFullyPaid ? 0.0 : remaining,
      isFullyPaid: isFullyPaid,
      previousBalance: previousAmount,
    );
  }

  void addTransaction(FinancialTransaction tx) {
    if (!_isMoneyAmount(tx.amount)) return;
    _transactions.insert(0, tx);
    _recalculateBudgets();
    _persistAll();
    notifyListeners();
  }

  String _titleForDraft(FinancialTransactionDraft draft) {
    return draft.description.isNotEmpty && draft.description != 'unknown' && draft.description != 'expense_other'
        ? draft.description
        : (draft.intent == 'income' ? 'Receita Recebida' : 'Despesa');
  }

  /// Returns [draft] with its category replaced by a remembered override when
  /// one exists for its description. Callers should apply this *before*
  /// building any UI text from the draft, so what's shown always matches what
  /// [addTransactionFromDraft] will actually save.
  FinancialTransactionDraft applyCategoryMemory(FinancialTransactionDraft draft) {
    final override = recallCategoryOverride(_titleForDraft(draft));
    if (override == null || override == draft.category) return draft;
    return draft.copyWith(category: override);
  }

  /// Saves [draft] and returns what was saved (empty when it has no amount),
  /// so the chat can later apply a correction or cancellation to exactly
  /// those records. Usually one transaction; a daily-rate draft ("50 o dia
  /// durante 10 dias", [FinancialTransactionDraft.repeatDays]) becomes one
  /// expense per day starting on the draft's date.
  List<FinancialTransaction> addTransactionFromDraft(FinancialTransactionDraft draft) {
    if (!_isMoneyAmount(draft.amount)) return const [];

    TransactionType type = TransactionType.expense;
    if (draft.intent == 'income') {
      type = TransactionType.income;
    } else if (draft.intent == 'transfer') {
      type = TransactionType.transfer;
    }

    final title = _titleForDraft(draft);

    // Category memory: if the user previously corrected how something like this
    // gets categorized, honor that from now on instead of the engine's guess.
    final rememberedCategory = recallCategoryOverride(title);

    final startDate = DateTime.now().add(Duration(days: draft.dateOffsetDays));
    final repeatDays = draft.repeatDays ?? 1;
    if (repeatDays > 1) {
      final baseId = _newId();
      final days = [
        for (var i = 0; i < repeatDays; i++)
          FinancialTransaction(
            id: '$baseId-d${i + 1}',
            title: '$title (${i + 1}/$repeatDays)',
            amount: draft.amount!,
            type: type,
            category: rememberedCategory ?? draft.category,
            paymentMethod: draft.paymentMethod,
            date: startDate.add(Duration(days: i)),
            bankSource: draft.bankSource,
          ),
      ];
      // Day 1 ends up on top of the (newest-first) list.
      _transactions.insertAll(0, days);
      _recalculateBudgets();
      _persistAll();
      notifyListeners();
      return days;
    }

    final tx = FinancialTransaction(
      id: _newId(),
      title: title,
      amount: draft.amount!,
      type: type,
      category: rememberedCategory ?? draft.category,
      paymentMethod: draft.paymentMethod,
      date: startDate,
      installments: draft.installments,
      currentInstallment: draft.installments != null && draft.installments! > 1 ? 1 : null,
      isRecurrent: draft.isRecurrent,
      dueDay: draft.dueDay,
      dueBusinessDay: draft.dueBusinessDay,
      billingDay: draft.billingDay,
      paymentMarginDays: draft.paymentMarginDays,
      bankSource: draft.bankSource,
      recurrenceDuration: draft.recurrenceDuration,
    );

    addTransaction(tx);
    return [tx];
  }

  /// Applies a chat correction ("na verdade foi no crédito em 3x", "na
  /// verdade é roupas") to the transaction it created. Before this, César
  /// only updated his own chat card and the saved record kept the old values.
  void applyDraftCorrection(String transactionId, FinancialTransactionDraft draft) {
    final idx = _transactions.indexWhere((t) => t.id == transactionId);
    if (idx == -1) return;
    final old = _transactions[idx];
    final isInstallment = draft.paymentMethod == 'credit_card' && (draft.installments ?? 1) > 1;
    _transactions[idx] = FinancialTransaction(
      id: old.id,
      title: old.title,
      amount: _isMoneyAmount(draft.amount) ? draft.amount! : old.amount,
      // A correction that didn't say the type ('unknown', 'query') keeps it —
      // an income used to become an expense (CHAOS-025).
      type: draft.intent == 'income'
          ? TransactionType.income
          : draft.intent == 'transfer'
              ? TransactionType.transfer
              : draft.intent == 'expense'
                  ? TransactionType.expense
                  : old.type,
      category: draft.category == 'unknown' ? old.category : draft.category,
      paymentMethod: draft.paymentMethod == 'unknown' ? old.paymentMethod : draft.paymentMethod,
      date: old.date,
      installments: isInstallment ? draft.installments : null,
      currentInstallment: isInstallment ? (old.currentInstallment ?? 1) : null,
      isRecurrent: old.isRecurrent,
      // A recurring draft carries its (possibly corrected) due rule.
      dueDay: old.isRecurrent ? (draft.dueDay ?? old.dueDay) : old.dueDay,
      dueBusinessDay: old.isRecurrent ? draft.dueBusinessDay : old.dueBusinessDay,
      billingDay: old.billingDay,
      paymentMarginDays: old.paymentMarginDays,
      recurrenceDuration: old.recurrenceDuration,
      bankSource: old.bankSource,
      notes: old.notes,
    );
    _recalculateBudgets();
    _persistAll();
    notifyListeners();
  }

  void deleteTransaction(String id) {
    _transactions.removeWhere((tx) => tx.id == id);
    _recalculateBudgets();
    _persistAll();
    notifyListeners();
  }

  /// Puts back records removed by [deleteTransaction] (César's "desfaz"),
  /// keeping their ids. Records whose id already exists are skipped.
  void restoreTransactions(List<FinancialTransaction> txs) {
    var changed = false;
    for (final tx in txs) {
      if (!_isMoneyAmount(tx.amount)) continue;
      if (_transactions.any((t) => t.id == tx.id)) continue;
      _transactions.insert(0, tx);
      changed = true;
    }
    if (!changed) return;
    _recalculateBudgets();
    _persistAll();
    notifyListeners();
  }

  void updateTransaction(FinancialTransaction tx) {
    if (!_isMoneyAmount(tx.amount)) return;
    final idx = _transactions.indexWhere((t) => t.id == tx.id);
    if (idx != -1) {
      _transactions[idx] = tx;
      _recalculateBudgets();
      _persistAll();
      notifyListeners();
    }
  }

  void setBudgetLimit(String category, double newLimit) {
    final idx = _budgets.indexWhere((b) => b.category == category);
    if (idx != -1) {
      _budgets[idx] = _budgets[idx].copyWith(monthlyLimit: newLimit);
      _recalculateBudgets();
      _persistAll();
      notifyListeners();
    }
  }

  /// Creates a new user-defined budget category alongside the built-in ones.
  /// The internal code is slugified from [name] so it behaves exactly like a
  /// built-in category everywhere else (transactions, reports, dashboard).
  /// Calling this again with the same name ("Pets", "PETS ") just updates
  /// that custom category's limit instead of creating a duplicate; a
  /// built-in's name ("Supermercado") returns the built-in untouched.
  /// A different name whose code is taken — "Supermarket" slugifies to the
  /// built-in `supermarket`, "!!!" and "???" both to `custom` — gets its own
  /// code instead of overwriting (renaming a built-in) the other category.
  BudgetCategory addBudgetCategory(String name, double monthlyLimit) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError('Category name is empty');
    if (!monthlyLimit.isFinite || monthlyLimit < 0) throw ArgumentError('Invalid monthly limit: $monthlyLimit');
    name = trimmed;

    final sameNameIndex = _budgets.indexWhere((b) =>
        _foldAccents(b.name.trim().toLowerCase()) == _foldAccents(name.toLowerCase()) || CategoryNameMatcher.sameName(b.name, name));
    if (sameNameIndex != -1) {
      final existing = _budgets[sameNameIndex];
      if (!existing.isCustom) return existing;
      final updated = existing.copyWith(monthlyLimit: monthlyLimit, name: name);
      _budgets[sameNameIndex] = updated;
      _persistAll();
      notifyListeners();
      return updated;
    }

    final baseCode = BudgetCategory.slugify(name);
    var code = baseCode;
    for (var n = 2; _budgets.any((b) => b.category == code); n++) {
      code = '${baseCode}_$n';
    }

    final newCategory = BudgetCategory(
      category: code,
      name: name,
      monthlyLimit: monthlyLimit,
      currentSpent: 0.0,
      icon: BudgetCategory.getIconForCategory(code),
      color: BudgetCategory.getColorForCategory(code),
      isCustom: true,
    );
    _budgets.add(newCategory);
    // A re-created category ("Pets" removed, then added back) must show the
    // spending its transactions still carry, not 0 until the next mutation.
    _recalculateBudgets();
    _persistAll();
    notifyListeners();
    return _budgets.last;
  }

  /// Removes a custom category. Built-in categories are protected — dropping
  /// one would silently orphan the dashboard's category breakdown for any
  /// existing transaction still tagged with it.
  void removeBudgetCategory(String category) {
    _budgets.removeWhere((b) => b.category == category && b.isCustom);
    _persistAll();
    notifyListeners();
  }

  /// Renames a custom category's display name. The internal code is kept as-is
  /// on purpose: every transaction, budget and remembered override keys off it,
  /// so renaming never has to touch past data (and the icon/color stay put).
  /// Returns false — and changes nothing — for built-in categories, an empty
  /// name, or a name another category already uses.
  bool renameBudgetCategory(String category, String newName) {
    final name = newName.trim();
    final idx = _budgets.indexWhere((b) => b.category == category && b.isCustom);
    if (idx == -1 || name.isEmpty) return false;

    final target = _foldAccents(name.toLowerCase());
    // Existing names are trimmed too: data saved before names were trimmed
    // ("PETS ") must still clash with "PETS" (CHAOS-023).
    final clashes = _budgets.any((b) =>
        b.category != category && (_foldAccents(b.name.trim().toLowerCase()) == target || CategoryNameMatcher.sameName(b.name, name)));
    if (clashes) return false;

    _budgets[idx] = _budgets[idx].copyWith(name: name);
    _persistAll();
    notifyListeners();
    return true;
  }

  /// Finds a custom category by display name or code (case/accent-insensitive)
  /// — used to resolve a spoken/typed category name like "pets" back to its
  /// internal code when the user corrects a transaction's category.
  String? findCustomCategoryCode(String name) {
    if (name.trim().isEmpty) return null;
    for (final b in _budgets) {
      if (!b.isCustom) continue;
      if (CategoryNameMatcher.sameName(b.name, name) || CategoryNameMatcher.sameName(b.category.replaceAll('_', ' '), name)) {
        return b.category;
      }
    }
    return null;
  }

  /// Custom categories as display name → code, for the NLP engine
  /// ([LocalFinancialNlpEngine.setCustomCategories]).
  Map<String, String> get customCategoryNames => {
        for (final b in _budgets)
          if (b.isCustom) b.name: b.category,
      };

  /// Wipes all data (transactions, reminders, goals, budgets reset to defaults,
  /// category memory) — used by "Limpar Histórico de Testes" in Ajustes.
  Future<void> clearAllData() async {
    _dataGeneration++;
    _transactions.clear();
    _reminders.clear();
    _goals.clear();
    _categoryOverrides.clear();
    _budgets.clear();
    _initializeDefaultBudgets();
    // Chained onto _pendingPersist (not called standalone) so an in-flight
    // save from a mutation that happened right before this can't complete
    // *after* the clear and resurrect the data it just wiped.
    final next = _pendingPersist.then((_) => _persistence.clearAll());
    _pendingPersist = next;
    // A write queued before the clear runs *before* it, so a mutation made
    // after this point must schedule its own write after the clear — or the
    // clear would wipe it.
    _persistQueued = false;
    await next;
    notifyListeners();
  }

  /// Overwrites everything with a snapshot pulled from the cloud (see
  /// `CloudSyncService`) — used the moment a signed-in user's Firestore data
  /// arrives, and also re-persists it locally so the on-device cache and the
  /// cloud agree. Kept Firebase-agnostic here on purpose: this repository
  /// never imports `cloud_firestore` itself, it just accepts plain data.
  void replaceAllFromCloud({
    required List<FinancialTransaction> transactions,
    required List<FinancialReminder> reminders,
    required List<BudgetCategory> budgets,
    required List<FinancialGoal> goals,
    required Map<String, String> categoryOverrides,
  }) {
    _dataGeneration++;
    _transactions
      ..clear()
      ..addAll(transactions);
    _reminders
      ..clear()
      ..addAll(reminders);
    if (budgets.isNotEmpty) {
      _budgets
        ..clear()
        ..addAll(budgets);
    }
    _goals
      ..clear()
      ..addAll(goals);
    _categoryOverrides
      ..clear()
      ..addAll(categoryOverrides);

    _recalculateBudgets();
    _persistAll();
    notifyListeners();
  }

  // ── SAVINGS GOALS ──

  void addGoal(FinancialGoal goal) {
    if (!_isStorableAmount(goal.targetAmount) || goal.targetAmount <= 0) return;
    _goals.insert(0, goal);
    _persistAll();
    notifyListeners();
  }

  /// Adds [amount] toward a goal's saved total, marking it completed once reached.
  FinancialGoal contributeToGoal(String goalId, double amount) {
    final idx = _goals.indexWhere((g) => g.id == goalId);
    if (idx == -1) {
      throw ArgumentError('Goal not found: $goalId');
    }
    final goal = _goals[idx];
    // NaN/∞ or a negative "contribution" is refused (withdrawing from a goal
    // is not this method's job) — the goal comes back unchanged.
    if (!amount.isFinite || amount <= 0) return goal;
    final newSaved = goal.savedAmount + amount;
    final updated = goal.copyWith(
      savedAmount: newSaved,
      isCompleted: newSaved >= goal.targetAmount,
    );
    _goals[idx] = updated;
    _persistAll();
    notifyListeners();
    return updated;
  }

  /// Takes [amount] back out of a goal ("tira 50 da meta da viagem"). Never
  /// goes below zero; a goal that drops under its target is active again.
  /// [contributeToGoal] refuses negative amounts on purpose, so this is the
  /// only way down.
  FinancialGoal withdrawFromGoal(String goalId, double amount) {
    final idx = _goals.indexWhere((g) => g.id == goalId);
    if (idx == -1) throw ArgumentError('Goal not found: $goalId');
    final goal = _goals[idx];
    if (!amount.isFinite || amount <= 0) return goal;
    final newSaved = (goal.savedAmount - amount).clamp(0.0, double.infinity);
    final updated = goal.copyWith(savedAmount: newSaved, isCompleted: newSaved >= goal.targetAmount);
    _goals[idx] = updated;
    _persistAll();
    notifyListeners();
    return updated;
  }

  void deleteGoal(String id) {
    _goals.removeWhere((g) => g.id == id);
    _persistAll();
    notifyListeners();
  }

  /// Finds an active (not completed) goal whose title matches [term] (substring,
  /// case/accent-insensitive) — used to resolve "quero colocar 200 na minha
  /// viagem" to the right goal.
  List<FinancialGoal> findGoalsByTitle(String term) {
    final target = _foldAccents(term.toLowerCase());
    if (target.isEmpty) return const [];
    return _goals.where((g) {
      if (g.isCompleted) return false;
      final candidate = _foldAccents(g.title.toLowerCase());
      return candidate.contains(target) || target.contains(candidate);
    }).toList();
  }

  // ── CATEGORY MEMORY (learns from corrections across sessions) ──

  /// Remembers that transactions described like [descriptionKey] should be
  /// categorized as [category] from now on, persisted across app restarts.
  void rememberCategoryOverride(String descriptionKey, String category) {
    final key = _foldAccents(descriptionKey.toLowerCase().trim());
    if (key.isEmpty) return;
    _categoryOverrides[key] = category;
    _persistAll();
  }

  /// Looks up a remembered category override for a transaction description, or
  /// null when the user never corrected this kind of item before.
  String? recallCategoryOverride(String description) {
    final key = _foldAccents(description.toLowerCase().trim());
    return _categoryOverrides[key];
  }

  void _recalculateBudgets() {
    // One pass over the transactions, not one per budget: this runs after
    // every mutation, and the per-budget rescan grew as budgets × history.
    final now = DateTime.now();
    final spentByCategory = <String, double>{};
    for (final tx in _transactions) {
      if (tx.type == TransactionType.expense && tx.date.year == now.year && tx.date.month == now.month) {
        spentByCategory[tx.category] = (spentByCategory[tx.category] ?? 0.0) + tx.amount;
      }
    }

    for (int i = 0; i < _budgets.length; i++) {
      _budgets[i] = _budgets[i].copyWith(currentSpent: spentByCategory[_budgets[i].category] ?? 0.0);
    }
  }

  // ── GETTERS & AGGREGATIONS ──

  double get totalBalance {
    double income = 0;
    double expense = 0;
    for (final tx in _transactions) {
      if (tx.type == TransactionType.income) {
        income += tx.amount;
      } else if (tx.type == TransactionType.expense || tx.type == TransactionType.transfer) {
        expense += tx.amount;
      }
    }
    return income - expense;
  }

  double get monthIncome {
    final now = DateTime.now();
    return _transactions
        .where((tx) =>
            tx.type == TransactionType.income &&
            tx.date.year == now.year &&
            tx.date.month == now.month)
        .fold(0.0, (acc, tx) => acc + tx.amount);
  }

  double get monthExpense {
    final now = DateTime.now();
    return _transactions
        .where((tx) =>
            (tx.type == TransactionType.expense || tx.type == TransactionType.transfer) &&
            tx.date.year == now.year &&
            tx.date.month == now.month)
        .fold(0.0, (acc, tx) => acc + tx.amount);
  }

  Map<String, double> get categoryExpensesThisMonth {
    final now = DateTime.now();
    final map = <String, double>{};
    for (final tx in _transactions) {
      if (tx.type == TransactionType.expense &&
          tx.date.year == now.year &&
          tx.date.month == now.month) {
        map[tx.category] = (map[tx.category] ?? 0.0) + tx.amount;
      }
    }
    return map;
  }

  /// Total expenses/income for an arbitrary [year]/[month], used to compare
  /// against the current month (see [monthOverMonthExpenseChange]).
  double expenseForMonth(int year, int month) {
    return _transactions
        .where((tx) =>
            (tx.type == TransactionType.expense || tx.type == TransactionType.transfer) &&
            tx.date.year == year &&
            tx.date.month == month)
        .fold(0.0, (acc, tx) => acc + tx.amount);
  }

  double incomeForMonth(int year, int month) {
    return _transactions
        .where((tx) => tx.type == TransactionType.income && tx.date.year == year && tx.date.month == month)
        .fold(0.0, (acc, tx) => acc + tx.amount);
  }

  /// Percentage change in expenses vs. the previous calendar month (positive =
  /// spent more than last month). Null when last month has no data to compare.
  double? get monthOverMonthExpenseChange {
    final now = DateTime.now();
    final prevMonth = DateTime(now.year, now.month - 1);
    final previous = expenseForMonth(prevMonth.year, prevMonth.month);
    if (previous <= 0) return null;
    return ((monthExpense - previous) / previous) * 100;
  }

  /// Proactive, unsolicited insights — the things César should mention on its
  /// own without being asked, rather than only when the user opens a screen.
  List<ProactiveAlert> getProactiveAlerts() {
    final alerts = <ProactiveAlert>[];
    final now = DateTime.now();

    for (final b in _budgets) {
      // A category created by chat without a limit ("cria a categoria
      // Viagens") has no budget to exceed yet.
      if (b.monthlyLimit <= 0) continue;
      if (b.isOverBudget) {
        alerts.add(ProactiveAlert(
          id: 'budget-over-${b.category}',
          message: 'Você já estourou o orçamento de ${b.name}: gastou R\$ ${b.currentSpent.toStringAsFixed(2).replaceAll('.', ',')} de um limite de R\$ ${b.monthlyLimit.toStringAsFixed(2).replaceAll('.', ',')}.',
          severity: ProactiveAlertSeverity.critical,
        ));
      } else if (b.isNearLimit) {
        final percent = (b.percentage * 100).toStringAsFixed(0);
        alerts.add(ProactiveAlert(
          id: 'budget-near-${b.category}',
          message: 'Atenção: você já usou $percent% do orçamento de ${b.name} este mês.',
          severity: ProactiveAlertSeverity.warning,
        ));
      }
    }

    final billsDueSoon = getUpcomingBills(start: now, end: now.add(const Duration(days: 3)));
    for (final bill in billsDueSoon) {
      final due = bill['dueDate'] as DateTime;
      final daysLeft = due.difference(DateTime(now.year, now.month, now.day)).inDays;
      final whenLabel = daysLeft <= 0 ? 'hoje' : (daysLeft == 1 ? 'amanhã' : 'em $daysLeft dias');
      alerts.add(ProactiveAlert(
        id: 'bill-${bill['id']}-${due.millisecondsSinceEpoch}',
        message: '${bill['title']} vence $whenLabel (R\$ ${(bill['amount'] as double).toStringAsFixed(2).replaceAll('.', ',')}).',
        severity: daysLeft <= 0 ? ProactiveAlertSeverity.critical : ProactiveAlertSeverity.warning,
      ));
    }

    for (final debtor in getActiveDebtors()) {
      if (debtor.targetDate.isBefore(now)) {
        final name = debtor.personName ?? debtor.title;
        final amountStr = debtor.amount != null ? 'R\$ ${debtor.amount!.toStringAsFixed(2).replaceAll('.', ',')}' : 'um valor';
        alerts.add(ProactiveAlert(
          id: 'debt-overdue-${debtor.id}',
          message: '$name ainda não te pagou os $amountStr combinados — já passou da data prevista.',
          severity: ProactiveAlertSeverity.info,
        ));
      }
    }

    return alerts;
  }

  List<FinancialTransaction> get recentTransactions {
    final sorted = List<FinancialTransaction>.from(_transactions)
      ..sort((a, b) => b.date.compareTo(a.date));
    return sorted.take(6).toList();
  }

  List<FinancialTransaction> get activeInstallments {
    return _transactions
        .where((tx) => tx.installments != null && tx.installments! > 1)
        .toList();
  }

  List<FinancialTransaction> get upcomingRecurrences {
    return _transactions.where((tx) => tx.isRecurrent).toList();
  }

  String generateAiInsight() {
    final spent = monthExpense;
    final earned = monthIncome;

    if (earned <= 0 && spent <= 0) {
      return 'Olá! Comece registrando suas receitas e despesas por voz ou texto para ativarmos as previsões inteligentes do Krezio.ai.';
    }

    final ratio = earned > 0 ? (spent / earned) : 1.0;

    if (ratio < 0.5) {
      final savedPercent = ((1.0 - ratio) * 100).toStringAsFixed(0);
      return 'Ótimo ritmo! Você já economizou $savedPercent% da sua renda deste mês. Que tal planejar um aporte para investimentos? ✨';
    } else if (ratio < 0.8) {
      return 'Seus gastos estão sob controle, ocupando ${(ratio * 100).toStringAsFixed(0)}% das suas receitas. Continue mantendo as contas de lazer dentro da meta!';
    } else if (ratio <= 1.0) {
      return 'Atenção ao fechamento: seus gastos já atingiram ${(ratio * 100).toStringAsFixed(0)}% das receitas. Evite novos parcelamentos nas próximas semanas.';
    } else {
      return 'Seus gastos deste mês superaram as receitas. Use o Assistente IA para identificar quais categorias podem ser reduzidas.';
    }
  }

  // ── ANALYTICAL & RAG QUERIES ──

  /// Returns all transactions occurring between [start] and [end] (inclusive).
  List<FinancialTransaction> getTransactionsBetween(DateTime start, DateTime end) {
    return _transactions.where((tx) {
      return (tx.date.isAfter(start) || tx.date.isAtSameMomentAs(start)) &&
          (tx.date.isBefore(end) || tx.date.isAtSameMomentAs(end));
    }).toList();
  }

  /// Finds transactions that match a category or description term (case-insensitive substring)
  /// optionally within a date range [start] and [end]. An empty [term] matches all expenses
  /// (used for generic queries like "quanto eu gastei esse mês?" with no category named).
  List<FinancialTransaction> getSpendingByCategoryOrTerm(
    String term, {
    DateTime? start,
    DateTime? end,
  }) {
    final lowerTerm = _foldAccents(term.toLowerCase().trim());
    // "no pix", "no crédito": a payment-method filter, not a text search.
    final paymentFilter = _paymentMethodForTerm(lowerTerm);
    // Category names are in Portuguese ("transporte", "saúde", "alimentação")
    // but codes are English (`transport`, `health`): comparing the term with
    // the code alone answered "R$ 0,00" for categories that had spending.
    final categoryCodes = lowerTerm.isEmpty || paymentFilter != null ? const <String>{} : _categoryCodesForTerm(lowerTerm);
    return _transactions.where((tx) {
      if (tx.type != TransactionType.expense) return false;

      if (start != null && tx.date.isBefore(start)) return false;
      if (end != null && tx.date.isAfter(end)) return false;

      if (lowerTerm.isEmpty) return true;
      if (paymentFilter != null) return tx.paymentMethod == paymentFilter;

      final titleMatch = _foldAccents(tx.title.toLowerCase()).contains(lowerTerm);
      final catMatch = tx.category.toLowerCase().contains(lowerTerm) || categoryCodes.contains(tx.category);
      return titleMatch || catMatch;
    }).toList();
  }

  static String? _paymentMethodForTerm(String term) {
    if (RegExp(r'^(?:o\s+|no\s+)?(?:pix|pics)$').hasMatch(term)) return 'pix';
    if (RegExp(r'^(?:cartao\s+de\s+)?debito$').hasMatch(term)) return 'debit_card';
    if (RegExp(r'^(?:cartao\s+de\s+)?credito$|^cartao$').hasMatch(term)) return 'credit_card';
    if (RegExp(r'^(?:dinheiro|especie)$').hasMatch(term)) return 'cash';
    if (RegExp(r'^boletos?$').hasMatch(term)) return 'bank_slip';
    return null;
  }

  static const Map<String, String> _categoryWordCodes = {
    'transporte': 'transport', 'combustivel': 'transport', 'saude': 'health', 'farmacia': 'health',
    'alimentacao': 'leisure', 'comida': 'leisure', 'lazer': 'leisure', 'restaurante': 'leisure',
    'mercado': 'supermarket', 'supermercado': 'supermarket', 'moradia': 'housing', 'casa': 'housing',
    'contas': 'housing', 'educacao': 'education', 'estudo': 'education', 'estudos': 'education', 'cursos': 'education',
  };

  /// Category codes whose Portuguese name (built-in word or the budget's
  /// display name, e.g. "Lazer & Alimentação") matches [foldedTerm].
  Set<String> _categoryCodesForTerm(String foldedTerm) {
    final codes = <String>{};
    final direct = _categoryWordCodes[foldedTerm];
    if (direct != null) codes.add(direct);
    for (final b in _budgets) {
      final words = _foldAccents(b.name.toLowerCase()).split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty);
      if (words.contains(foldedTerm) || CategoryNameMatcher.sameName(b.name, foldedTerm)) codes.add(b.category);
    }
    return codes;
  }

  /// Aggregates total spending for [term] within the given date bounds.
  double getTotalSpendingByCategoryOrTerm(
    String term, {
    DateTime? start,
    DateTime? end,
  }) {
    final matches = getSpendingByCategoryOrTerm(term, start: start, end: end);
    return matches.fold(0.0, (acc, tx) => acc + tx.amount);
  }

  /// Returns active debtors from reminders of type `loanReceivable` that are not completed.
  /// Optionally filters by target payment date between [start] and [end].
  List<FinancialReminder> getActiveDebtors({
    DateTime? start,
    DateTime? end,
  }) {
    return _reminders.where((r) {
      if (r.type != ReminderType.loanReceivable || r.isCompleted) return false;
      if (start != null && r.targetDate.isBefore(start)) return false;
      if (end != null && r.targetDate.isAfter(end)) return false;
      return true;
    }).toList();
  }

  /// Finds active debtors whose person name matches [name] (case/accent-insensitive,
  /// substring match so "joão" also matches a reminder named "João Silva").
  List<FinancialReminder> findDebtorsByName(String name) {
    final target = _foldAccents(name.toLowerCase());
    if (target.isEmpty) return const [];
    return getActiveDebtors().where((r) {
      final candidate = _foldAccents((r.personName ?? r.title).toLowerCase());
      return candidate.contains(target) || target.contains(candidate);
    }).toList();
  }

  static String _foldAccents(String text) {
    const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
    const to = 'aaaaaeeeeiiiiooooouuuucn';
    var result = text;
    for (var i = 0; i < from.length; i++) {
      result = result.replaceAll(from[i], to[i]);
    }
    return result;
  }

  /// Retrieves upcoming bills and recurring commitments, combining transactions with due days
  /// and reminders of type `billPayment`.
  List<Map<String, dynamic>> getUpcomingBills({
    DateTime? start,
    DateTime? end,
  }) {
    final now = DateTime.now();
    final effectiveStart = start ?? DateTime(now.year, now.month, now.day);
    final effectiveEnd = end ?? effectiveStart.add(const Duration(days: 14));

    final results = <Map<String, dynamic>>[];

    // 1. Recurring transactions or transactions with dueDay
    for (final tx in _transactions.where((t) => t.type == TransactionType.expense && (t.isRecurrent || t.dueDay != null))) {
      final dueDay = tx.dueDay ?? tx.date.day;
      final billDay = tx.billingDay;
      final margin = tx.paymentMarginDays ?? (billDay != null ? (dueDay - billDay).abs() : null);

      // Check current month and next month dates
      for (int mOffset = 0; mOffset <= 1; mOffset++) {
        final year = now.year;
        final month = now.month + mOffset;
        final actualYear = month > 12 ? year + 1 : year;
        final actualMonth = month > 12 ? month - 12 : month;
        final daysInMonth = DateTime(actualYear, actualMonth + 1, 0).day;
        // "5º dia útil" falls on a different date every month.
        final safeDueDay = tx.dueBusinessDay != null
            ? RealtimeCalendarService.nthBusinessDay(DateTime(actualYear, actualMonth), tx.dueBusinessDay!).day
            : dueDay.clamp(1, daysInMonth);

        final dueDate = DateTime(actualYear, actualMonth, safeDueDay, 23, 59, 59);

        DateTime? billingDate;
        if (billDay != null) {
          final safeBillDay = billDay.clamp(1, daysInMonth);
          billingDate = DateTime(actualYear, actualMonth, safeBillDay, 0, 0, 0);
        }

        if ((dueDate.isAfter(effectiveStart) || dueDate.isAtSameMomentAs(effectiveStart)) &&
            (dueDate.isBefore(effectiveEnd) || dueDate.isAtSameMomentAs(effectiveEnd))) {
          results.add({
            'id': tx.id,
            'title': tx.title,
            'amount': tx.amount,
            'category': tx.category,
            'dueDate': dueDate,
            'billingDate': billingDate,
            'billingDay': billDay,
            'dueDay': safeDueDay,
            'dueBusinessDay': tx.dueBusinessDay,
            'paymentMarginDays': margin,
            'source': 'transaction',
          });
        }
      }
    }

    // 2. Bill reminders
    for (final r in _reminders.where((rem) => rem.type == ReminderType.billPayment && !rem.isCompleted)) {
      if ((r.targetDate.isAfter(effectiveStart) || r.targetDate.isAtSameMomentAs(effectiveStart)) &&
          (r.targetDate.isBefore(effectiveEnd) || r.targetDate.isAtSameMomentAs(effectiveEnd))) {
        results.add({
          'id': r.id,
          'title': r.title,
          'amount': r.amount ?? 0.0,
          'category': 'bills',
          'dueDate': r.targetDate,
          'billingDate': r.billingDate,
          'billingDay': r.billingDate?.day,
          'dueDay': r.targetDate.day,
          'paymentMarginDays': r.paymentMarginDays,
          'source': 'reminder',
        });
      }
    }

    results.sort((a, b) => (a['dueDate'] as DateTime).compareTo(b['dueDate'] as DateTime));
    return results;
  }

  /// Adds a bill with explicit billing and due days and calculates margin.
  void addBillWithMargin({
    required String title,
    required int billingDay,
    required int dueDay,
    double? amount,
    String? category,
  }) {
    // No value, no bill: a R$ 0 entry is not something the user paid (CHAOS-022).
    if (amount == null || !amount.isFinite || amount <= 0) return;
    final now = DateTime.now();
    final margin = (dueDay - billingDay).abs();

    final tx = FinancialTransaction(
      id: _newId('margin-bill-'),
      title: title,
      amount: amount,
      type: TransactionType.expense,
      category: category ?? 'housing',
      date: DateTime(now.year, now.month, dueDay.clamp(1, 28)),
      isRecurrent: true,
      billingDay: billingDay,
      dueDay: dueDay,
      paymentMarginDays: margin,
      paymentMethod: 'bank_slip',
    );

    addTransaction(tx);
  }
}
