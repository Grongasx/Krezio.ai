import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

void main() {
  group('AffordabilityAnalyzer.isAffordabilityQuestion', () {
    test('recognizes common phrasings', () {
      expect(AffordabilityAnalyzer.isAffordabilityQuestion('posso comprar um notebook de 3000?'), isTrue);
      expect(AffordabilityAnalyzer.isAffordabilityQuestion('consigo comprar um tenis de 400?'), isTrue);
      expect(AffordabilityAnalyzer.isAffordabilityQuestion('da pra comprar uma bicicleta de 900?'), isTrue);
      expect(AffordabilityAnalyzer.isAffordabilityQuestion('vale a pena comprar essa tv de 2000?'), isTrue);
    });

    test('does not misfire on an ordinary expense statement', () {
      expect(AffordabilityAnalyzer.isAffordabilityQuestion('comprei um notebook de 3000 no pix'), isFalse);
    });
  });

  group('AffordabilityAnalyzer.analyze', () {
    late FinancialRepository repository;
    late AffordabilityAnalyzer analyzer;

    setUp(() {
      repository = FinancialRepository();
      analyzer = AffordabilityAnalyzer(repository: repository);
    });

    test('returns null for a non-affordability phrase', () {
      expect(analyzer.analyze('gastei 50 no mercado'), isNull);
    });

    test('says yes when the purchase is small and safely within balance/budget', () {
      final result = analyzer.analyze('posso comprar um livro de 50 reais?');
      expect(result, isNotNull);
      expect(result!.verdict, AffordabilityVerdict.yes);
      expect(result.amount, 50.0);
      expect(result.spokenText, contains('Sim'));
    });

    test('says no when the amount exceeds the current balance', () {
      // Seeded balance is a few thousand reais; ask for something absurdly large.
      final hugeAmount = repository.totalBalance + 100000;
      final result = analyzer.analyze('posso comprar uma casa de R\$ ${hugeAmount.toStringAsFixed(0)}?');
      expect(result, isNotNull);
      expect(result!.verdict, AffordabilityVerdict.no);
      expect(result.spokenText, contains('não cobre'));
    });

    test('urges caution when it would blow the category budget', () {
      // Seeded 'leisure' budget limit is 600.0 with 0 spent by default in a fresh repo.
      final result = analyzer.analyze('posso comprar um violao de 900 reais?');
      expect(result, isNotNull);
      expect(result!.verdict, isNot(AffordabilityVerdict.yes));
      expect(result.formattedText, contains('estouraria o orçamento'));
    });

    test('urges caution when upcoming bills + goal contributions eat into what would be left', () {
      // Push the balance down close to zero so the small remainder can't cover commitments.
      repository.addTransaction(FinancialTransaction(
        id: 'drain-1',
        title: 'Grande despesa',
        amount: repository.totalBalance - 100,
        type: TransactionType.expense,
        category: 'expense_other',
        paymentMethod: 'pix',
        date: DateTime.now(),
      ));
      repository.addGoal(FinancialGoal(
        id: 'goal-1',
        title: 'Viagem',
        targetAmount: 3000,
        targetDate: DateTime(DateTime.now().year, DateTime.now().month + 1, 1),
      ));

      final result = analyzer.analyze('posso comprar um fone de 80 reais?');
      expect(result, isNotNull);
      expect(result!.verdict, AffordabilityVerdict.caution);
    });

    test('extracts a plausible item label from the question', () {
      final result = analyzer.analyze('posso comprar uma cadeira gamer de 800 reais?');
      expect(result, isNotNull);
      expect(result!.itemLabel, contains('cadeira gamer'));
    });
  });
}
