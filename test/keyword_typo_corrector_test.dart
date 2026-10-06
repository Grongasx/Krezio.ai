import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/keyword_typo_corrector.dart';

void main() {
  group('KeywordTypoCorrector — erros de digitação nas palavras-chave (CONV-028)', () {
    test('corrige categoria, forma de pagamento e verbo com erro pequeno', () {
      const cases = {
        'mercadp': 'mercado',
        'mercao': 'mercado',
        'farmasia': 'farmacia',
        'restaurate': 'restaurante',
        'acadmia': 'academia',
        'credto': 'credito',
        'gstei': 'gastei',
        'gasteu': 'gastei',
        'gsatei': 'gastei', // letras trocadas
        'padria': 'padaria',
        'debtio': 'debito',
      };
      cases.forEach((typo, expected) => expect(KeywordTypoCorrector.correct(typo), expected, reason: typo));
    });

    test('palavras comuns do português perto de uma palavra-chave não são "corrigidas"', () {
      for (final w in [
        'gostei', 'gastou', 'gasto', 'porto', 'posto', 'cantar', 'virgem', 'lancha', 'bolero', 'credita', 'debate',
        'academico', 'academica', 'recebe', 'compre', 'alugue', 'mercadoria',
      ]) {
        expect(KeywordTypoCorrector.correct(w), isNull, reason: w);
      }
    });

    test('palavras curtas, plurais e flexões ficam como estão', () {
      for (final w in ['pix', 'fix', 'bar', 'casa', 'uber', 'boletos', 'mercados', 'academias', 'restaurantes', 'presentes']) {
        expect(KeywordTypoCorrector.correct(w), isNull, reason: w);
      }
    });

    test('palavra que o chamador conhece (vocabulário do modelo) não é tocada', () {
      expect(KeywordTypoCorrector.correct('mercadp', isKnownWord: (w) => w == 'mercadp'), isNull);
    });

    test('correctText troca só as palavras erradas e preserva números e pontuação', () {
      expect(KeywordTypoCorrector.correctText('gasteu 45,90 no mercao, no credto.'), 'gastei 45,90 no mercado, no credito.');
      expect(KeywordTypoCorrector.correctText('gostei do porto, 50 no pix'), 'gostei do porto, 50 no pix');
    });

    // R2-CHAOS-001…006/019: palavras reais a uma edição de uma palavra-chave
    // eram "corrigidas" e mudavam tipo, categoria ou pagamento. A regra agora é
    // estrutural (só conta como erro o que parece escorregão de dedo: letra
    // vizinha no teclado, som igual, letra faltando/dobrada, letras trocadas).
    // Das 55 abaixo, 31 eram corrigidas antes (marcado, deito, vagem, lance,
    // pararia, gestei, mentalidade, transfiro, aluguei...).
    test('R2-CHAOS-001…006: 55 palavras reais próximas de palavras-chave ficam como estão', () {
      const realWords = [
        // viravam palavra-chave antes desta regra
        'marcado', 'farmaco', 'brinquei', 'deito', 'visagem', 'pararia', 'lance', 'vagem', 'solario', 'delito',
        'demito', 'almaco', 'facilidade', 'pradaria', 'pagaria', 'podaria', 'presidente', 'prudente', 'pretende',
        'presenca', 'juntar', 'jantam', 'recebo', 'transfira', 'pressente', 'aluguei', 'aluguem', 'condominial',
        'gestei', 'transfiro', 'mentalidade',
        // vizinhas que precisam continuar intactas
        'gostei', 'devido', 'bolota', 'boleia', 'credor', 'lances', 'vagens', 'marcada', 'parada', 'mercante',
        'almofada', 'salada', 'janela', 'farinha', 'fazenda', 'merecido', 'bolada', 'gasosa', 'boletim', 'cineasta',
        'debate', 'presencial', 'drogado', 'pedestre',
      ];
      expect(realWords.length, greaterThanOrEqualTo(40));
      final changed = {
        for (final w in realWords)
          if (KeywordTypoCorrector.correct(w) != null) w: KeywordTypoCorrector.correct(w),
      };
      expect(changed, isEmpty);
    });

    test('palavra escrita com acento ou ç foi escrita de propósito', () {
      for (final w in ['solário', 'almaço', 'presença', 'fármaco', 'condômino', 'débito', 'crédito', 'almoço']) {
        expect(KeywordTypoCorrector.correct(w), isNull, reason: w);
      }
    });

    test('erros de digitação novos (escorregão de dedo) continuam corrigidos', () {
      const cases = {
        'mercdo': 'mercado', // letra faltando
        'farmacai': 'farmacia', // letras trocadas
        'acdemia': 'academia',
        'gasolna': 'gasolina',
        'alugel': 'aluguel',
        'salaio': 'salario',
        'dinheior': 'dinheiro',
        'boelto': 'boleto',
        'recbi': 'recebi',
        'viajem': 'viagem', // g/j soam igual
        'cinwma': 'cinema', // w é vizinha do e
        'credoto': 'credito', // o é vizinha do i
        'presemte': 'presente', // m é vizinha do n
        'mensalidde': 'mensalidade',
        'estacionamneto': 'estacionamento',
        'restaurnate': 'restaurante',
      };
      cases.forEach((typo, expected) => expect(KeywordTypoCorrector.correct(typo), expected, reason: typo));
    });

    test('palavras-chave que decidem o tipo (salário, recebi, transferi) só aceitam 1 escorregão', () {
      expect(KeywordTypoCorrector.correct('salaroi'), 'salario');
      expect(KeywordTypoCorrector.correct('sslaroi'), isNull);
      expect(KeywordTypoCorrector.correct('trasnferi'), 'transferi');
      expect(KeywordTypoCorrector.correct('trasnfeir'), isNull);
    });

    test('distância de digitação: vizinha no teclado conta, letra distante não', () {
      expect(KeywordTypoCorrector.typoDistance('mercadp', 'mercado', limit: 1), 1);
      expect(KeywordTypoCorrector.typoDistance('solario', 'salario', limit: 1), 2);
      expect(KeywordTypoCorrector.typoDistance('delito', 'debito', limit: 1), 2);
      expect(KeywordTypoCorrector.typoDistance('pradaria', 'padaria', limit: 1), 2);
      expect(KeywordTypoCorrector.areNeighbourKeys('o', 'p'), isTrue);
      expect(KeywordTypoCorrector.areNeighbourKeys('a', 'o'), isFalse);
    });

    test('distância de edição conta troca de letras vizinhas como 1', () {
      expect(KeywordTypoCorrector.distance('gsatei', 'gastei'), 1);
      expect(KeywordTypoCorrector.distance('mercao', 'mercado'), 1);
      expect(KeywordTypoCorrector.distance('abc', 'xyz', limit: 1), 2);
    });
  });
}
