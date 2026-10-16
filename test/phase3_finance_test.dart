import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/backend/models/budget_category.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

BudgetCategory budget(double limit, double spent) => BudgetCategory(
    category: 'leisure', name: 'Lazer', monthlyLimit: limit, currentSpent: spent, icon: Icons.star, color: Colors.purple);

void main() {
  group('3.6 faixas do orçamento', () {
    test('verde até 79%, amarelo 80–99%, vermelho a partir de 100%', () {
      expect(budget(400, 316).level, BudgetLevel.ok);
      expect(budget(400, 320).level, BudgetLevel.warning);
      expect(budget(400, 399).level, BudgetLevel.warning);
      expect(budget(400, 400).level, BudgetLevel.over);
      expect(budget(400, 430).level, BudgetLevel.over);
    });

    test('"faltam" e "passou"', () {
      expect(budget(400, 320).statusText, 'Faltam R\$ 80,00');
      expect(budget(400, 430).statusText, 'Passou R\$ 30,00');
      expect(budget(400, 400).statusText, 'No limite');
      expect(budget(5000, 1000).statusText, 'Faltam R\$ 4.000,00');
    });
  });

  group('3.2 apagar categoria move os lançamentos', () {
    test('nenhum lançamento fica sem categoria', () {
      final repo = FinancialRepository();
      final pets = repo.addBudgetCategory('Pets', 200);
      repo.addTransaction(FinancialTransaction(
          id: 'a', title: 'Ração', amount: 90, type: TransactionType.expense, category: pets.category, paymentMethod: 'pix', date: DateTime.now()));
      repo.rememberCategoryOverride('racao', pets.category);
      repo.removeBudgetCategory(pets.category, moveTo: 'supermarket');
      expect(repo.budgets.any((b) => b.category == pets.category), isFalse);
      expect(repo.transactions.firstWhere((t) => t.id == 'a').category, 'supermarket');
      expect(repo.categoryOverrides.values, isNot(contains(pets.category)));
    });
  });

  group('3.2 categoria com o nome de uma nativa', () {
    test('"Supermarket" é a nativa Supermercado, não uma nova', () {
      final repo = FinancialRepository();
      final count = repo.budgets.length;
      expect(repo.existingCategoryNamed('Supermarket')?.name, 'Supermercado');
      expect(repo.existingCategoryNamed('supermercado')?.category, 'supermarket');
      expect(repo.addBudgetCategory('Supermarket', 300).category, 'supermarket');
      expect(repo.budgets.length, count);
      expect(repo.existingCategoryNamed('Academia'), isNull);
    });
  });

  group('3.8 contas em aberto', () {
    test('ordenadas por vencimento, atrasada detectada, pagar cria o lançamento', () {
      final repo = FinancialRepository();
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      repo.addReminder(FinancialReminder(id: 'luz', title: 'Luz', amount: 180, targetDate: today.add(const Duration(days: 5)), type: ReminderType.billPayment));
      repo.addReminder(FinancialReminder(id: 'net', title: 'Internet', amount: 100, targetDate: today.subtract(const Duration(days: 2)), type: ReminderType.billPayment));
      repo.addReminder(FinancialReminder(id: 'joao', title: 'João', personName: 'João', amount: 50, targetDate: today, type: ReminderType.loanReceivable));

      expect(repo.openBills.map((r) => r.id), ['net', 'luz']);
      expect(FinancialRepository.isOverdue(repo.openBills.first, now), isTrue);
      expect(FinancialRepository.isOverdue(repo.openBills.last, now), isFalse);

      final before = repo.transactions.length;
      final tx = repo.payBill('net')!;
      expect(tx.amount, 100);
      expect(tx.type, TransactionType.expense);
      expect(repo.transactions.length, before + 1);
      expect(repo.openBills.map((r) => r.id), ['luz']);
      expect(repo.payBill('net'), isNull, reason: 'conta já paga não paga de novo');
    });
  });
}
