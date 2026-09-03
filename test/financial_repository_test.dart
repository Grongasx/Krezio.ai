import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/core/models/financial_transaction.dart';
import 'package:krezio_ai/core/repositories/financial_repository.dart';
import 'package:krezio_ai/core/ml/local_nlp_engine.dart';

void main() {
  late FinancialRepository repository;

  setUp(() {
    repository = FinancialRepository();
  });

  group('FinancialRepository - Testes de Gestão e Agregações', () {
    test('Inicialização contém transações e orçamentos padrão', () {
      expect(repository.transactions.isNotEmpty, true);
      expect(repository.budgets.isNotEmpty, true);
      expect(repository.totalBalance, isNotNull);
    });

    test('Adiciona nova transação e recalcula saldo e métricas', () {
      final initialBalance = repository.totalBalance;
      final tx = FinancialTransaction(
        id: 'test-1',
        title: 'Bônus de Desempenho',
        amount: 1000.0,
        type: TransactionType.income,
        category: 'salary',
        paymentMethod: 'pix',
        date: DateTime.now(),
      );

      repository.addTransaction(tx);
      expect(repository.totalBalance, initialBalance + 1000.0);
    });

    test('Adiciona transação a partir de FinancialTransactionDraft (NLP)', () {
      final draft = FinancialTransactionDraft(
        intent: 'expense',
        intentConfidence: 1.0,
        category: 'leisure',
        paymentMethod: 'credit_card',
        amount: 85.0,
        dateOffsetDays: 0,
        description: 'Restaurante Madero',
        rawText: 'gastei 85 no madero no credito',
        latencyMs: 1.2,
        isComplete: true,
        missingSlots: [],
        installments: 2,
        isRecurrent: false,
      );

      final countBefore = repository.transactions.length;
      repository.addTransactionFromDraft(draft);
      expect(repository.transactions.length, countBefore + 1);

      final added = repository.transactions.first;
      expect(added.title, 'Restaurante Madero');
      expect(added.amount, 85.0);
      expect(added.type, TransactionType.expense);
      expect(added.installments, 2);
    });

    test('Exclusão de transação atualiza repositório', () {
      final tx = FinancialTransaction(
        id: 'del-1',
        title: 'Café',
        amount: 15.0,
        type: TransactionType.expense,
        category: 'leisure',
        paymentMethod: 'cash',
        date: DateTime.now(),
      );

      repository.addTransaction(tx);
      expect(repository.transactions.any((t) => t.id == 'del-1'), true);

      repository.deleteTransaction('del-1');
      expect(repository.transactions.any((t) => t.id == 'del-1'), false);
    });

    test('Ajuste de limite de orçamento por categoria', () {
      repository.setBudgetLimit('supermarket', 1500.0);
      final budget = repository.budgets.firstWhere((b) => b.category == 'supermarket');
      expect(budget.monthlyLimit, 1500.0);
    });

    test('Geração de Insight de IA é empático e coerente', () {
      final insight = repository.generateAiInsight();
      expect(insight.isNotEmpty, true);
      expect(insight, isNot(contains('Déficit Orçamentário')));
    });
  });
}
