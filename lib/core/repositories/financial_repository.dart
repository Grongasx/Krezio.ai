import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/financial_transaction.dart';
import '../models/budget_category.dart';
import '../ml/local_nlp_engine.dart';

class FinancialRepository extends ChangeNotifier {
  final List<FinancialTransaction> _transactions = [];
  final List<BudgetCategory> _budgets = [];

  FinancialRepository() {
    _initializeDefaultBudgets();
    _seedInitialData();
  }

  List<FinancialTransaction> get transactions => List.unmodifiable(_transactions);
  List<BudgetCategory> get budgets => List.unmodifiable(_budgets);

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
    _recalculateBudgets();
  }

  // ── MUTATIONS ──

  void addTransaction(FinancialTransaction tx) {
    _transactions.insert(0, tx);
    _recalculateBudgets();
    notifyListeners();
  }

  void addTransactionFromDraft(FinancialTransactionDraft draft) {
    if (draft.amount == null || draft.amount! <= 0) return;

    TransactionType type = TransactionType.expense;
    if (draft.intent == 'income') {
      type = TransactionType.income;
    } else if (draft.intent == 'transfer') {
      type = TransactionType.transfer;
    }

    String title = draft.description.isNotEmpty && draft.description != 'unknown' && draft.description != 'expense_other'
        ? draft.description
        : (draft.intent == 'income' ? 'Receita Recebida' : 'Despesa');

    final tx = FinancialTransaction(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      amount: draft.amount!,
      type: type,
      category: draft.category,
      paymentMethod: draft.paymentMethod,
      date: DateTime.now().add(Duration(days: draft.dateOffsetDays)),
      installments: draft.installments,
      currentInstallment: draft.installments != null && draft.installments! > 1 ? 1 : null,
      isRecurrent: draft.isRecurrent,
      dueDay: draft.dueDay,
      bankSource: draft.bankSource,
    );

    addTransaction(tx);
  }

  void deleteTransaction(String id) {
    _transactions.removeWhere((tx) => tx.id == id);
    _recalculateBudgets();
    notifyListeners();
  }

  void updateTransaction(FinancialTransaction tx) {
    final idx = _transactions.indexWhere((t) => t.id == tx.id);
    if (idx != -1) {
      _transactions[idx] = tx;
      _recalculateBudgets();
      notifyListeners();
    }
  }

  void setBudgetLimit(String category, double newLimit) {
    final idx = _budgets.indexWhere((b) => b.category == category);
    if (idx != -1) {
      _budgets[idx] = _budgets[idx].copyWith(monthlyLimit: newLimit);
      _recalculateBudgets();
      notifyListeners();
    }
  }

  void _recalculateBudgets() {
    final now = DateTime.now();
    final currentMonthExpenses = _transactions.where((tx) =>
        tx.type == TransactionType.expense &&
        tx.date.year == now.year &&
        tx.date.month == now.month);

    for (int i = 0; i < _budgets.length; i++) {
      final cat = _budgets[i].category;
      final spent = currentMonthExpenses
          .where((tx) => tx.category == cat)
          .fold(0.0, (acc, tx) => acc + tx.amount);
      _budgets[i] = _budgets[i].copyWith(currentSpent: spent);
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
}
