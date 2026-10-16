import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/backend/models/financial_account.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/credit_card_invoice.dart';

FinancialTransaction buy(String id, double amount, DateTime date, {String? account, int? inst}) => FinancialTransaction(
    id: id, title: 'Compra $id', amount: amount, type: TransactionType.expense, category: 'supermarket',
    paymentMethod: 'credit_card', date: date, accountId: account, installments: inst);

void main() {
  group('3.3 contas e carteiras', () {
    test('conta principal sempre existe; nome repetido é recusado', () {
      final repo = FinancialRepository();
      expect(repo.accounts.first.id, FinancialAccount.mainId);
      expect(repo.addAccount('Nubank'), isNotNull);
      expect(repo.addAccount('nubank '), isNull);
      expect(repo.addAccount('  '), isNull);
      expect(repo.addAccount('Cartão', kind: AccountKind.creditCard), isNull, reason: 'cartão exige fechamento e vencimento');
      expect(repo.archiveAccount(FinancialAccount.mainId), isFalse);
    });

    test('saldo por conta + total; transferência própria não muda o total', () {
      final repo = FinancialRepository();
      final totalBefore = repo.totalBalance;
      final mainBefore = repo.balanceOf(FinancialAccount.mainId);
      final poup = repo.addAccount('Poupança', kind: AccountKind.savings)!;
      final tx = repo.transferBetweenAccounts(from: FinancialAccount.mainId, to: poup.id, amount: 500)!;
      expect(tx.isInternalTransfer, isTrue);
      expect(repo.totalBalance, closeTo(totalBefore, 0.001));
      expect(repo.balanceOf(poup.id), 500);
      expect(repo.balanceOf(FinancialAccount.mainId), closeTo(mainBefore - 500, 0.001));
      expect(repo.transferBetweenAccounts(from: poup.id, to: poup.id, amount: 10), isNull);
    });

    test('conta arquivada sai da escolha mas mantém o histórico', () {
      final repo = FinancialRepository();
      final c = repo.addAccount('Carteira', kind: AccountKind.wallet)!;
      repo.addTransaction(FinancialTransaction(
          id: 'w1', title: 'Café', amount: 8, type: TransactionType.expense, category: 'leisure', paymentMethod: 'cash',
          date: DateTime.now(), accountId: c.id));
      repo.archiveAccount(c.id);
      expect(repo.activeAccounts.any((a) => a.id == c.id), isFalse);
      expect(repo.accounts.any((a) => a.id == c.id), isTrue);
      expect(repo.balanceOf(c.id), -8);
      expect(repo.renameAccount(c.id, 'Conta principal'), isFalse, reason: 'nome já usado');
    });

    test('conta e transferência sobrevivem ao JSON', () {
      final a = FinancialAccount(id: 'x', name: 'Itaú', kind: AccountKind.creditCard, closingDay: 3, dueDay: 10);
      final b = FinancialAccount.fromJson(a.toJson());
      expect([b.name, b.kind, b.closingDay, b.dueDay], ['Itaú', AccountKind.creditCard, 3, 10]);
      final t = FinancialTransaction.fromJson(FinancialTransaction(
              id: 't', title: 'T', amount: 1, type: TransactionType.transfer, category: 'transfer', paymentMethod: 'pix',
              date: DateTime(2026), accountId: 'main', toAccountId: 'x')
          .toJson());
      expect([t.accountId, t.toAccountId], ['main', 'x']);
      expect(FinancialTransaction.fromJson({'id': 'old', 'title': 'Antigo', 'amount': 5, 'date': '2026-01-01'}).account, 'main');
    });
  });

  group('3.3 fatura do cartão', () {
    const card = FinancialAccount(id: 'card', name: 'Nubank', kind: AccountKind.creditCard, closingDay: 3, dueDay: 10);

    test('compra antes do fechamento: fatura deste mês; no dia ou depois: a próxima', () {
      expect(CreditCardInvoice.dueFor(DateTime(2026, 10, 2), closingDay: 3, dueDay: 10), DateTime(2026, 10, 10));
      expect(CreditCardInvoice.dueFor(DateTime(2026, 10, 3), closingDay: 3, dueDay: 10), DateTime(2026, 11, 10));
      expect(CreditCardInvoice.dueFor(DateTime(2026, 12, 20), closingDay: 3, dueDay: 10), DateTime(2027, 1, 10));
      // Vencimento antes do fechamento no calendário: vence no mês seguinte.
      expect(CreditCardInvoice.dueFor(DateTime(2026, 10, 1), closingDay: 25, dueDay: 5), DateTime(2026, 11, 5));
      // Dia 31 em mês curto.
      expect(CreditCardInvoice.dueFor(DateTime(2027, 2, 10), closingDay: 31, dueDay: 8), DateTime(2027, 3, 8));
    });

    test('parcelas somam o total, arredondamento na última', () {
      expect(CreditCardInvoice.split(1200, 10), List.filled(10, 120.0));
      final p = CreditCardInvoice.split(100, 3);
      expect(p, [33.33, 33.33, 33.34]);
      expect(p.reduce((a, b) => a + b), closeTo(100, 1e-9));
    });

    test('total da fatura com à vista e parcelado', () {
      final txs = [
        buy('a', 300, DateTime(2026, 10, 1), account: 'card'), // fatura de 10/10
        buy('b', 1200, DateTime(2026, 9, 20), account: 'card', inst: 10), // 1ª em 10/10
        buy('c', 50, DateTime(2026, 10, 5), account: 'card'), // fatura de 10/11
        buy('d', 999, DateTime(2026, 10, 1)), // outra conta
      ];
      expect(CreditCardInvoice.total(txs, card, DateTime(2026, 10)), 420);
      expect(CreditCardInvoice.total(txs, card, DateTime(2026, 11)), 170);
      final last = CreditCardInvoice.items(txs, card, DateTime(2027, 7));
      expect(last.single.installmentLabel, 'Parcela 10/10');
      expect(CreditCardInvoice.items(txs, card, DateTime(2027, 8)), isEmpty);
    });
  });
}
