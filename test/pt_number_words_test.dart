import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/pt_number_words.dart';

void main() {
  group('Número por extenso pt-BR (PtNumberWords.parse)', () {
    final cases = <String, double>{
      'um': 1,
      'dez': 10,
      'quinze': 15,
      'vinte e cinco': 25,
      'quarenta e cinco': 45,
      'cem': 100,
      'cento e vinte': 120,
      'cento e cinquenta': 150,
      'trezentos e noventa e nove': 399,
      'setecentos e cinquenta': 750,
      'mil': 1000,
      'mil e duzentos': 1200,
      'mil e quinhentos': 1500,
      'dois mil e quinhentos': 2500,
      'cem mil e um': 100001,
      'meio milhão': 500000,
      'um milhão e meio': 1500000,
      'dois e meio': 2.5,
      '10 mil': 10000,
      '1,5 mil': 1500,
      '2 milhões': 2000000,
      'vinte e cinco vírgula cinquenta': 25.5,
      'três vírgula zero cinco': 3.05,
      'cinquenta centavos': 0.5,
      'doze reais e cinquenta centavos': 12.5,
      'cinquenta e dois reais e noventa centavos': 52.9,
      '50 reais e 90 centavos': 50.9,
      'um real e cinquenta': 1.5,
      'cinquenta reais': 50,
      'oitenta e sete e cinquenta': 87.5,
      'dezenove e noventa': 19.9,
    };
    cases.forEach((phrase, expected) {
      test('"$phrase" = $expected', () {
        expect(PtNumberWords.parse(phrase), closeTo(expected, 0.0001));
      });
    });

    test('não é número: texto comum, "cento" sozinho, dois números seguidos', () {
      expect(PtNumberWords.parse('mercado'), isNull);
      expect(PtNumberWords.parse('cento'), isNull);
      expect(PtNumberWords.parse('dois três'), isNull);
      expect(PtNumberWords.parse('cinco e dois'), isNull);
    });
  });

  group('Número por extenso dentro da frase (PtNumberWords.normalize)', () {
    test('converte o valor e mantém o resto da frase', () {
      expect(PtNumberWords.normalize('gastei cinquenta e dois reais e noventa centavos no mercado no pix'),
          'gastei 52,90 reais no mercado no pix');
      expect(PtNumberWords.normalize('paguei mil e duzentos de aluguel'), 'paguei 1200 de aluguel');
      expect(PtNumberWords.normalize('gastei R\$ 10 mil no carro no pix'), 'gastei R\$ 10000 no carro no pix');
      expect(PtNumberWords.normalize('gastei vinte e cinco vírgula cinquenta na padaria'), 'gastei 25,50 na padaria');
      expect(PtNumberWords.normalize('gastei 50 reais e 90 centavos no mercado'), 'gastei 50,90 reais no mercado');
    });

    test('artigo "um"/"uma" não vira número; "por cento" não vira 100', () {
      expect(PtNumberWords.normalize('comprei um tênis de trezentos e noventa e nove no crédito em três vezes'),
          'comprei um tênis de 399 no crédito em 3 vezes');
      expect(PtNumberWords.normalize('paguei de uma vez'), 'paguei de uma vez');
      expect(PtNumberWords.normalize('dez por cento de desconto'), '10 por cento de desconto');
    });

    test('"50 reais e 30 na farmácia" continua sendo duas compras', () {
      expect(PtNumberWords.normalize('gastei 50 reais e 30 na farmácia'), 'gastei 50 reais e 30 na farmácia');
    });

    test('vírgula de pontuação separa números', () {
      expect(PtNumberWords.normalize('dois, três'), '2, 3');
    });
  });
}
