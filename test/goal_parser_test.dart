import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/goal_parser.dart';

void main() {
  group('GoalParser: criação de metas', () {
    test('parses "quero juntar 5000 para uma viagem até dezembro"', () {
      final match = GoalParser.parseCreation('quero juntar 5000 para uma viagem até dezembro');
      expect(match, isNotNull);
      expect(match!.title, 'Viagem');
      expect(match.targetAmount, 5000.0);
      expect(match.targetDate, isNotNull);
      expect(match.targetDate!.month, 12);
    });

    test('parses "quero guardar 3000 pro notebook" (sem data)', () {
      final match = GoalParser.parseCreation('quero guardar 3000 pro notebook');
      expect(match, isNotNull);
      expect(match!.title, 'Notebook');
      expect(match.targetAmount, 3000.0);
      expect(match.targetDate, isNull);
    });

    test('parses "criar meta de 2000 para o curso até junho de 2026"', () {
      final match = GoalParser.parseCreation('criar meta de 2000 para o curso até junho de 2026');
      expect(match, isNotNull);
      expect(match!.title, 'Curso');
      expect(match.targetAmount, 2000.0);
      expect(match.targetDate!.year, 2026);
      expect(match.targetDate!.month, 6);
    });

    test('does not misfire on an ordinary expense', () {
      expect(GoalParser.parseCreation('gastei 50 no mercado no pix'), isNull);
      expect(GoalParser.isGoalCreationPhrase('gastei 50 no mercado no pix'), isFalse);
    });
  });

  group('GoalParser: contribuição para metas', () {
    test('parses "guardei 100 na minha meta da viagem"', () {
      final match = GoalParser.parseContribution('guardei 100 na minha meta da viagem');
      expect(match, isNotNull);
      expect(match!.goalTitle, 'viagem');
      expect(match.amount, 100.0);
    });

    test('parses "coloquei 50 na meta do notebook"', () {
      final match = GoalParser.parseContribution('coloquei 50 na meta do notebook');
      expect(match, isNotNull);
      expect(match!.goalTitle, 'notebook');
      expect(match.amount, 50.0);
    });

    test('does not misfire on goal creation phrasing', () {
      expect(GoalParser.parseContribution('quero juntar 5000 para uma viagem'), isNull);
    });
  });
}
