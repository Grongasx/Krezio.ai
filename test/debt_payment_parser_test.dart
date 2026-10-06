import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

void main() {
  group('DebtPaymentParser', () {
    test('parses the exact reported phrase: partial payment with "porém apenas"', () {
      final match = DebtPaymentParser.parse('o joão me pagou a divida dele, porém apenas 70 reais');
      expect(match, isNotNull);
      expect(match!.personName, 'João');
      expect(match.amountPaid, 70.0);
    });

    test('parses "a Maria me devolveu 50 reais"', () {
      final match = DebtPaymentParser.parse('a Maria me devolveu 50 reais');
      expect(match, isNotNull);
      expect(match!.personName, 'Maria');
      expect(match.amountPaid, 50.0);
    });

    test('parses "recebi 100 do Pedro" (bare number, no currency word)', () {
      final match = DebtPaymentParser.parse('recebi 100 do Pedro');
      expect(match, isNotNull);
      expect(match!.personName, 'Pedro');
      expect(match.amountPaid, 100.0);
    });

    test('parses "o joão quitou a divida" with R\$ amount', () {
      final match = DebtPaymentParser.parse('o joão quitou a dívida com R\$ 150,00');
      expect(match, isNotNull);
      expect(match!.personName, 'João');
      expect(match.amountPaid, 150.0);
    });

    test('does not match an unrelated income phrase', () {
      // The verb pattern alone is ambiguous ("recebi ... de ..." also reads this way),
      // but a plain income noun like "salário" must never be mistaken for a person's
      // name, so parse() must still come back null.
      expect(DebtPaymentParser.parse('recebi 3000 de salário'), isNull);
      expect(DebtPaymentParser.parse('recebi 100 de reembolso'), isNull);
    });

    test('returns null when a payment verb is found but no amount is stated', () {
      expect(DebtPaymentParser.parse('o joão me pagou'), isNull);
    });
  });

  group('FinancialRepository debt payment integration', () {
    late FinancialRepository repo;

    setUp(() {
      repo = FinancialRepository();
    });

    test('applyDebtPayment reduces the balance and keeps the reminder pending on a partial payment', () {
      final joao = repo.findDebtorsByName('joão').single;
      expect(joao.amount, 150.00);

      final result = repo.applyDebtPayment(joao.id, 70.0);

      expect(result.isFullyPaid, isFalse);
      expect(result.amountPaid, 70.0);
      expect(result.remainingBalance, closeTo(80.0, 0.001));
      expect(result.reminder.amount, closeTo(80.0, 0.001));
      expect(result.reminder.isCompleted, isFalse);

      // The debt is still active with the reduced balance.
      final stillActive = repo.getActiveDebtors();
      expect(stillActive.any((d) => d.id == joao.id && d.amount == result.remainingBalance), isTrue);

      // The amount actually received was recorded as income.
      expect(repo.transactions.any((t) => t.amount == 70.0 && t.title.contains('João')), isTrue);
    });

    test('applyDebtPayment marks the reminder completed when fully paid', () {
      final joao = repo.findDebtorsByName('joão').single;

      final result = repo.applyDebtPayment(joao.id, 150.0);

      expect(result.isFullyPaid, isTrue);
      expect(result.remainingBalance, 0.0);
      expect(repo.getActiveDebtors().any((d) => d.id == joao.id), isFalse);
    });

    test('an over-payment also settles the debt without a negative balance', () {
      final joao = repo.findDebtorsByName('joão').single;

      final result = repo.applyDebtPayment(joao.id, 200.0);

      expect(result.isFullyPaid, isTrue);
      expect(result.remainingBalance, 0.0);
    });

    test('findDebtorsByName is accent and case insensitive', () {
      expect(repo.findDebtorsByName('JOAO').length, 1);
      expect(repo.findDebtorsByName('joão').length, 1);
      expect(repo.findDebtorsByName('joao').length, 1);
      expect(repo.findDebtorsByName('ninguem-com-esse-nome'), isEmpty);
    });
  });

  group('QA CONV-012/013: renda comum não é pagamento de dívida', () {
    test('possessivos e fontes de renda não viram nome de devedor', () {
      for (final p in [
        'Recebi o pagamento do meu salário no valor de R\$ 5.200,00.',
        'o chefe me pagou 1500 do bico',
        'recebi 50 conto da minha vó',
        'trabalhei 12 horas e recebi 400 de diária no pix',
      ]) {
        expect(DebtPaymentParser.parse(p), isNull, reason: p);
      }
    });

    test('pessoa de verdade continua sendo reconhecida', () {
      expect(DebtPaymentParser.parse('a maria me devolveu 50')?.personName, 'Maria');
      expect(DebtPaymentParser.parse('recebi 100 do pedro')?.personName, 'Pedro');
    });

    test('sem dívida no nome, o aviso explica que virou receita comum', () {
      final repo = FinancialRepository();
      final match = DebtPaymentParser.parse('a maria me devolveu 50')!;
      expect(repo.findDebtorsByName(match.personName), isEmpty);
      expect(DebtPaymentParser.noOpenDebtNote(match.personName), contains('receita comum'));
    });
  });

  group('CONV-026: pagamento parcial sem "me pagou"', () {
    test('"o joão pagou 50 do que me devia"', () {
      final m = DebtPaymentParser.parse('o joão pagou 50 do que me devia')!;
      expect(m.personName, 'João');
      expect(m.amountPaid, 50);
    });
    test('não confunde com gasto: "paguei 50 do que devia ao banco"', () {
      expect(DebtPaymentParser.parse('paguei 50 no mercado'), isNull);
    });
  });

  group('QA CONV-036: resposta ao pagamento de dívida', () {
    test('pagou a mais: quita e comenta o excedente', () {
      final t = DebtPaymentParser.paymentReply('João', paid: 300, remaining: 0, fullyPaid: true, excess: 150);
      expect(t, contains('quitou a dívida de R\$ 150,00'));
      expect(t, contains('sobraram R\$ 150,00 a mais'));
      expect(t, contains('R\$ 300,00'));
    });

    test('pagou exato ou parcial: sem falar de excedente', () {
      expect(DebtPaymentParser.paymentReply('Maria', paid: 150, remaining: 0, fullyPaid: true), isNot(contains('a mais')));
      final partial = DebtPaymentParser.paymentReply('Maria', paid: 50, remaining: 100, fullyPaid: false);
      expect(partial, contains('Restam R\$ 100,00'));
      expect(partial, isNot(contains('a mais')));
    });
  });
}
