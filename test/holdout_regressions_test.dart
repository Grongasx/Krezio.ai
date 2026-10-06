import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/money_direction.dart';
import 'package:krezio_ai/ai/reference_edit_parser.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

/// Regressions found by an independent held-out check (frases que nenhum
/// agente tinha visto) after the R2 battery reached 279/279.
void main() {
  final budgets = FinancialRepository().budgets;
  final now = DateTime(2026, 9, 24);

  group('Comentário sobre algo não edita lançamento (holdout P0)', () {
    // "o mercado tá caro demais hoje em dia" renomeou "Supermercado Carrefour"
    // para "Caro demais dia" e mudou a data dele para hoje.
    for (final remark in [
      'o mercado tá caro demais hoje em dia',
      'o uber tá caro hoje',
      'a feira tava boa ontem',
      'o aluguel tá pesado esse mês',
      'o posto tá cheio hoje',
      'a padaria de ontem tava uma delícia',
      'o restaurante foi ótimo no sábado',
      'a academia tá lotada essa semana',
    ]) {
      test('"$remark" não é edição', () {
        expect(ReferenceEditParser.parse(remark, now: now, budgets: budgets), isNull);
      });
    }

    test('edição sem verbo nunca renomeia', () {
      final edit = ReferenceEditParser.parse('o açougue foi 95', now: now, budgets: budgets);
      expect(edit, isNotNull);
      expect(edit!.changes.title, isNull);
    });

    for (final edit in [
      'o açougue de anteontem foi 92',
      'aquela da sorveteria foi no débito',
      'a pizzaria agora é 98',
      'o do posto foi pra encher o tanque do carro da minha mãe, foi no pix',
      'o salário chegou 4800 esse mês',
    ]) {
      test('"$edit" continua sendo edição', () {
        expect(ReferenceEditParser.parse(edit, now: now, budgets: budgets), isNotNull);
      });
    }
  });

  group('Terceiro que paga: entrada, ou pergunta se pagou algo meu (holdout P0)', () {
    // "o inquilino transferiu o aluguel, 1350 no pix" era salvo como despesa.
    for (final incoming in [
      'o inquilino transferiu o aluguel, 1350 no pix',
      'minha tia mandou um presente de 200 no pix',
      'a empresa depositou o vale de 600',
      'o cliente pixou o serviço, 480',
      'o chefe pagou 180 no pix',
    ]) {
      test('"$incoming" é entrada', () {
        expect(MoneyDirectionDetector.detect(incoming), MoneyDirection.incoming);
      });
    }

    for (final paidForMe in [
      'meu pai pagou minha conta de luz de 150',
      'minha mãe pagou meu boleto da faculdade, 700',
    ]) {
      test('"$paidForMe" pergunta (não entrou nem saiu dinheiro meu)', () {
        expect(MoneyDirectionDetector.detect(paidForMe), MoneyDirection.conflict);
      });
    }

    for (final outgoing in ['eu paguei o aluguel de 1400 no pix', 'a gente pagou 300 no hotel']) {
      test('"$outgoing" é saída', () {
        expect(MoneyDirectionDetector.detect(outgoing), MoneyDirection.outgoing);
      });
    }

    test('sem valor, terceiro pagando não decide nada', () {
      expect(MoneyDirectionDetector.detect('a maria pagou o almoço'), MoneyDirection.unknown);
    });
  });
}
