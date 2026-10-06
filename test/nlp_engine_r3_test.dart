// Rodada 3 do corretor: regras estruturais para os achados R2-CHAOS/R2-CONV.
// Cada grupo valida com frases que NÃO estão nos relatórios, para provar que a
// regra generalizou (ver "Contra overfitting" na skill krezio-fix-issues).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';

void main() {
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  String shape(FinancialTransactionDraft d) => '${d.intent}/${d.category}/${d.paymentMethod}/${d.amount}';

  group('R2-CHAOS-001…006, 019, 020: palavra real não muda tipo, categoria nem pagamento', () {
    // A frase com a palavra real tem de dar o mesmo resultado que a mesma frase
    // com uma palavra neutra no lugar.
    test('pares palavra real × palavra neutra dão o mesmo lançamento', () {
      const pairs = [
        // tipo (salário)
        ['gastei 70 no solario do prédio no pix', 'gastei 70 no terraço do prédio no pix'],
        // categoria (mercado, viagem, lanche, padaria, faculdade, presente)
        ['paguei 90 no horário marcado com o fulano no pix', 'paguei 90 no horário combinado com o fulano no pix'],
        ['gastei 25 na vagem e na couve no pix', 'gastei 25 na abobrinha e na couve no pix'],
        ['dei um lance de 300 no leilão no pix', 'dei um valor de 300 no leilão no pix'],
        ['paguei 60 pro jardineiro que pararia o serviço no pix', 'paguei 60 pro jardineiro que terminaria o serviço no pix'],
        ['paguei 45 pela mentalidade de economizar no pix', 'paguei 45 pela ideia de economizar no pix'],
        ['paguei 200 pro assessor da presidente no pix', 'paguei 200 pro assessor da diretora no pix'],
        ['gastei 35 que o fulano pretende devolver no pix', 'gastei 35 que o fulano quer devolver no pix'],
        // pagamento (débito)
        ['paguei 150 ao despachante, deito cedo hoje', 'paguei 150 ao despachante, durmo cedo hoje'],
        ['paguei 40 pelo devido conserto', 'paguei 40 pelo necessário conserto'],
        // palavra-chave dentro de outra palavra (R2-CHAOS-006/020)
        ['paguei 30 pela segunda via do extrato no pix', 'paguei 30 pela segunda via do documento no pix'],
        ['gastei 50 com a família no pix', 'gastei 50 com a turma no pix'],
        ['paguei 60 pelo histórico no pix', 'paguei 60 pelo documento no pix'],
        ['gastei 45 com o camarão no pix', 'gastei 45 com o peixe no pix'],
        ['paguei 35 pra telefonista no pix', 'paguei 35 pra atendente no pix'],
        ['comprei um adesivo pixelado de 15', 'comprei um adesivo colorido de 15'],
        ['gastei 20 no app picsart', 'gastei 20 no app fulano'],
      ];
      final diffs = <String>[];
      for (final p in pairs) {
        final a = engine.parse(p[0]), b = engine.parse(p[1]);
        if (shape(a) != shape(b)) diffs.add('${p[0]} => ${shape(a)}  ≠  ${shape(b)}');
      }
      expect(diffs, isEmpty);
    });

    test('palavra real nunca fixa a forma de pagamento que o usuário não disse', () {
      for (final s in [
        'paguei 150 ao despachante, deito cedo hoje',
        'gastei 90 no advogado por causa do delito de trânsito',
        'paguei 70 da multa e demito o motorista amanhã',
        'paguei 100 ao credor do meu pai',
        'gastei 30 no app picsart',
        'comprei um adesivo pixelado de 15',
      ]) {
        expect(engine.parse(s).paymentMethod, 'unknown', reason: s);
      }
    });

    test('palavra real parecida com "salário" não vira receita', () {
      for (final s in ['gastei 70 no solario do prédio no pix', 'paguei 40 de solário no pix', 'paguei 55 no solarium no débito']) {
        final d = engine.parse(s);
        expect(d.intent, 'expense', reason: s);
        expect(d.category, isNot('salary'), reason: s);
      }
    });

    test('os erros de digitação de verdade continuam funcionando no motor', () {
      final a = engine.parse('gasteu 45,90 no mercdo no credoto a vista');
      expect(a.intent, 'expense');
      expect(a.category, 'supermarket');
      expect(a.paymentMethod, 'credit_card');
      final b = engine.parse('paguei 30 na farmasia no debtio');
      expect(b.category, 'health');
      expect(b.paymentMethod, 'debit_card');
      expect(engine.parse('gastei 40 no mercado no pixx').paymentMethod, 'pix');
    });
  });

  group('R2-CONV-002/003/017: quem paga quem decide receita × despesa', () {
    test('o usuário pagando é despesa, com verbos e registros novos', () {
      const phrases = {
        'Informo a quitação da anuidade do conselho, R\$ 480,00, via Pix.': 'expense',
        'larguei a academia mas paguei 90 da multa de cancelamento no débito': 'expense',
        'saiu 45 da minha conta de tarifa do banco': 'expense',
        'recebi a conta de luz de 180 no boleto': 'expense',
        'me cobraram 35 de taxa de entrega no pix': 'expense',
        'comprei um tênis de 200 no pix e ganhei uma meia': 'expense',
      };
      phrases.forEach((p, type) {
        final d = engine.parse(p);
        expect(d.intent, type, reason: p);
        expect(const {'salary', 'income_other'}.contains(d.category), isFalse, reason: '$p → ${d.category}');
      });
    });

    test('dinheiro dado, pago ou depositado para o usuário é receita', () {
      for (final p in [
        'minha vó me passou 200 no pix pra ajudar',
        'o cliente acertou 750 do serviço no pix',
        'a empresa depositou 2300 de salário',
        'vendi minha bike e o comprador pagou 800 no pix',
        'Solicito o lançamento de uma receita de R\$ 1.200,00 relativa a aluguel recebido, via Pix.',
        'meu irmão me mandou 50 no pix pro lanche',
        'a firma depositou 3100 do mês',
      ]) {
        final d = engine.parse(p);
        expect(d.intent, 'income', reason: p);
        expect(d.amount, isNotNull, reason: p);
      }
    });

    test('sinais nos dois sentidos: pergunta o tipo em vez de chutar, e a resposta decide', () {
      final d = engine.parse('paguei 50 no mercado e me devolveram 20 no pix');
      expect(d.missingSlots, contains('type'));
      expect(d.isComplete, isFalse);
      expect(d.clarificationPrompt, contains('entrou'));
      final out = engine.mergeDrafts(d, 'saiu');
      expect(out.intent, 'expense');
      expect(out.missingSlots, isNot(contains('type')));
      final inc = engine.mergeDrafts(engine.parse('gastei 80 e o joão me pagou 80 no pix'), 'foi receita');
      expect(inc.intent, 'income');
      final still = engine.mergeDrafts(d, 'hmm');
      expect(still.missingSlots, contains('type'));
      expect(still.isComplete, isFalse);
    });
  });

  group('R2-CONV-012: N meses de X de V = N × V, pago de uma vez (não é assinatura nova)', () {
    test('outros N, serviços e verbos', () {
      const cases = {
        'paguei 12 meses de aluguel da garagem de 180 no pix': 2160.0,
        'adiantei 2 meses de mensalidade da escola do meu filho de 650 no boleto': 1300.0,
        'quitei 5 meses de condomínio atrasado de 420 no pix': 2100.0,
        'paguei 3 meses de plano de saúde de 310 no débito': 930.0,
        'paguei 10 meses de natação de 95 no pix': 950.0,
      };
      cases.forEach((p, total) {
        final d = engine.parse(p);
        expect(d.amount, total, reason: p);
        expect(d.isRecurrent, isFalse, reason: p);
        expect(d.missingSlots, isNot(contains('due_day')), reason: p);
        expect(d.description.toLowerCase(), isNot('meses'), reason: p);
      });
      // decisão pendente mantida: "3 meses de academia de 100" = 300
      expect(engine.parse('paguei 3 meses de academia de 100').amount, 300.0);
    });

    test('medidas continuam fora da conta', () {
      expect(engine.parse('comprei 10 litros de gasolina de 60 no pix').amount, 60.0);
      expect(engine.parse('gastei 50 reais de uber no pix').amount, 50.0);
    });
  });

  group('R2-CONV-013: multi com receitas; pedaço sem vocabulário não herda categoria', () {
    test('receitas em lote viram vários lançamentos', () {
      for (final e in {
        'ganhei 150 de bico e 90 de gorjeta no pix': [150.0, 90.0],
        'recebi 2000 do salário, 300 de comissão e 120 de reembolso no pix': [2000.0, 300.0, 120.0],
        'recebi 450 da diária e 60 de gorjeta no pix': [450.0, 60.0],
      }.entries) {
        final r = engine.parseMulti(e.key);
        expect(r.map((d) => d.amount), e.value, reason: e.key);
        expect(r.every((d) => d.intent == 'income'), isTrue, reason: e.key);
      }
    });

    test('pedaço com palavra desconhecida pergunta a categoria, com o nome dito', () {
      for (final e in {
        'paguei 30 no estacionamento e 15 no chaveiro no pix': 'Chaveiro',
        'comprei 40 de ração e 25 no borracheiro no débito': 'Borracheiro',
        'gastei 20 na farmácia e 35 no sapateiro no pix': 'Sapateiro',
      }.entries) {
        final last = engine.parseMulti(e.key).last;
        expect(last.category, 'unknown', reason: e.key);
        expect(last.missingSlots, contains('category'), reason: e.key);
        expect(last.description, e.value, reason: e.key);
        // resposta que César não entende não salva com um palpite
        expect(engine.mergeDrafts(last, 'hmm sei lá').isComplete, isFalse, reason: e.key);
      }
    });

    test('comentário sobre o primeiro valor não vira lançamento', () {
      for (final p in ['gastei 60 no açougue, mas achei que seria só 40', 'paguei 80 no gás e não 70']) {
        expect(engine.parseMulti(p).length, 1, reason: p);
      }
    });
  });

  group('R2-CONV-014: "me deve N" pega o valor e o texto do lembrete não se repete', () {
    test('valor extraído em frases novas', () {
      for (final e in {
        'a carla me deve 75 da pizza': 75.0,
        'minha irmã me deve 250 do aluguel': 250.0,
        'o vizinho me deve 60 e vai me pagar quando receber o salário': 60.0,
        'o thiago ainda me deve 42,50 do ingresso': 42.5,
      }.entries) {
        final d = engine.parse(e.key);
        expect(d.amount, e.value, reason: e.key);
        expect(d.isReminder, isTrue, reason: e.key);
        expect(d.reminderType, 'loan_receivable', reason: e.key);
      }
    });

    test('pergunta do valor sem data não inventa "cai no dia no 5º dia útil"', () {
      final d = engine.parse('o joão me deve');
      expect(d.missingSlots, contains('amount'));
      expect(d.clarificationPrompt, isNot(contains('dia no')));
      expect(d.clarificationPrompt, contains('Qual foi o valor'));
      final withDate = LocalFinancialNlpEngine.loanReminderText(personName: 'Pedro', targetDate: DateTime(2026, 10, 7), amount: 120);
      expect(withDate, contains('07/10'));
      expect(withDate, contains('R\$ 120,00'));
      final noDate = LocalFinancialNlpEngine.loanReminderText(personName: 'Pedro', targetDate: null, amount: 120);
      expect(noDate, isNot(contains('dia útil')));
    });
  });
}
