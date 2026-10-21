// Feedback real do usuário (2026-10-16): lançamentos múltiplos com
// quantificador de grupo ("ambos", "os dois", "cada um"…), mensalidade paga
// no passado, compra parcelada com dia de vencimento das parcelas e "5º dia
// útil" contando o sábado. Cada grupo traz frases que não estavam no relato,
// para provar que a regra generalizou ("Contra overfitting").
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/entry_safety_gate.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/calendar_service.dart';

void main() {
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  String item(FinancialTransactionDraft d) =>
      '${d.description}|${d.amount}|${d.category}|${d.paymentMethod}|${d.installments}|${d.dateOffsetDays}';

  /// Every item complete, nothing asked, nothing recurring.
  void allSettled(List<FinancialTransactionDraft> ds, String reason) {
    for (final d in ds) {
      expect(d.isComplete, isTrue, reason: '$reason → ${item(d)} falta ${d.missingSlots}');
      expect(d.isRecurrent, isFalse, reason: '$reason → ${item(d)}');
    }
    expect(engine.multiClarificationPrompt(ds), isNull, reason: reason);
  }

  group('Lançamentos múltiplos: quantificador de grupo vale para o grupo inteiro', () {
    test('a frase do usuário: 4 lançamentos, nada perguntado', () {
      final ds = engine.parseMulti(
          'Gastei 100 reais na mensalidade da academia no pix, comprei 1 whey protein por 250 e albumina por 75, ambos no cartão de '
          'crédito parcelado em 3 vezes e gastei 75 no dinheiro para lavar o carro. Tudo no dia de hoje');
      expect(ds.map(item), [
        'Academia|100.0|health|pix|null|0',
        'Whey|250.0|health|credit_card|3|0',
        'Albumina|75.0|health|credit_card|3|0',
        'Lavagem do carro|75.0|transport|cash|null|0',
      ]);
      allSettled(ds, 'frase do usuário');
    });

    test('"ambos"/"os dois"/"as duas" no meio da frase: os dois itens antes', () {
      final cases = <String, List<String>>{
        // ordem trocada: o grupo vem primeiro
        'comprei whey por 250 e albumina por 75 os dois no crédito em 3x e paguei 100 da academia no pix': [
          'Whey|250.0|health|credit_card|3|0',
          'Albumina|75.0|health|credit_card|3|0',
          'Academia|100.0|health|pix|null|0',
        ],
        // "e mais 75 no dinheiro pra lavar o carro"
        'paguei 100 de academia no pix, comprei creatina por 120 e colágeno por 90, os dois no crédito em 3x, e mais 75 no dinheiro pra lavar o carro': [
          'Academia|100.0|health|pix|null|0',
          'Creatina|120.0|health|credit_card|3|0',
          'Colágeno|90.0|health|credit_card|3|0',
          'Lavagem do carro|75.0|transport|cash|null|0',
        ],
        // fala transcrita, sem vírgulas
        'gastei 100 na academia no pix comprei whey por 250 e albumina por 75 ambos no credito parcelado em 3 vezes e gastei 75 no dinheiro pra lavar o carro tudo hoje': [
          'Academia|100.0|health|pix|null|0',
          'Whey|250.0|health|credit_card|3|0',
          'Albumina|75.0|health|credit_card|3|0',
          'Lavagem do carro|75.0|transport|cash|null|0',
        ],
        'gastei 60 no mercado no pix e comprei um caderno por 20 e uma caneta por 5 ambos no dinheiro': [
          'Mercado|60.0|supermarket|pix|null|0',
          'Caderno|20.0|education|cash|null|0',
          'Caneta|5.0|education|cash|null|0',
        ],
        'comprei whey por 250 e albumina por 75 ambos no débito': [
          'Whey|250.0|health|debit_card|null|0',
          'Albumina|75.0|health|debit_card|null|0',
        ],
      };
      for (final e in cases.entries) {
        final ds = engine.parseMulti(e.key);
        expect(ds.map(item), e.value, reason: e.key);
        allSettled(ds, e.key);
      }
    });

    test('"todos", "cada um", "os 3": o grupo da oração (ou a frase inteira, no fim)', () {
      final cases = <String, List<String>>{
        'comprei arroz por 30 e feijão por 12 todos no pix e gastei 40 no uber no débito': [
          'Arroz|30.0|supermarket|pix|null|0',
          'Feijão|12.0|supermarket|pix|null|0',
          'Uber|40.0|transport|debit_card|null|0',
        ],
        'comprei pão por 10 e leite por 6 cada um no débito e paguei 50 de luz no pix': [
          'Pão|10.0|supermarket|debit_card|null|0',
          'Leite|6.0|supermarket|debit_card|null|0',
          'Luz|50.0|housing|pix|null|0',
        ],
        // três itens num grupo
        'comprei camiseta por 80, bermuda por 60 e tênis por 300, os 3 no crédito em 2x, e gastei 20 no uber no pix': [
          'Camiseta|80.0|expense_other|credit_card|2|0',
          'Bermuda|60.0|expense_other|credit_card|2|0',
          'Tênis|300.0|expense_other|credit_card|2|0',
          'Uber|20.0|transport|pix|null|0',
        ],
        'gastei 30 no uber, 25 no ifood e 40 no cinema, todos no pix': [
          'Uber|30.0|transport|pix|null|0',
          'Ifood|25.0|leisure|pix|null|0',
          'Cinema|40.0|leisure|pix|null|0',
        ],
      };
      for (final e in cases.entries) {
        final ds = engine.parseMulti(e.key);
        expect(ds.map(item), e.value, reason: e.key);
        allSettled(ds, e.key);
      }
    });

    test('grupos diferentes com pagamentos diferentes, e datas por grupo', () {
      final cases = <String, List<String>>{
        'comprei whey por 250 e albumina por 75 ambos no crédito em 3x e gastei 30 no mercado e 20 na padaria os dois no pix': [
          'Whey|250.0|health|credit_card|3|0',
          'Albumina|75.0|health|credit_card|3|0',
          'Mercado|30.0|supermarket|pix|null|0',
          'Padaria|20.0|supermarket|pix|null|0',
        ],
        'comprei whey por 250 e albumina por 75, os dois ontem no pix, e gastei 40 no uber hoje no débito': [
          'Whey|250.0|health|pix|null|-1',
          'Albumina|75.0|health|pix|null|-1',
          'Uber|40.0|transport|debit_card|null|0',
        ],
        'gastei 50 no mercado no pix e 30 na farmácia no débito tudo ontem': [
          'Mercado|50.0|supermarket|pix|null|-1',
          'Farmácia|30.0|health|debit_card|null|-1',
        ],
      };
      for (final e in cases.entries) {
        final ds = engine.parseMulti(e.key);
        expect(ds.map(item), e.value, reason: e.key);
        allSettled(ds, e.key);
      }
    });

    test('o pagamento de um grupo não vaza para item fora dele: pergunta', () {
      final ds = engine.parseMulti('comprei whey por 250 e albumina por 75 ambos no crédito em 3x e gastei 30 no mercado');
      expect(ds.map((d) => d.amount), [250.0, 75.0, 30.0]);
      expect(ds[0].paymentMethod, 'credit_card');
      expect(ds[1].paymentMethod, 'credit_card');
      expect(ds[2].paymentMethod, 'unknown');
      expect(ds[2].missingSlots, contains('payment_method'));
      expect(engine.multiClarificationPrompt(ds), contains('R\$ 30,00 (Mercado)'));
    });

    test('nenhum valor some: "os dois amigos" não é quantificador; "2 pizzas de 40 cada uma" não é grupo', () {
      final bar = engine.parseMulti('gastei 50 no mercado e 30 no bar com os dois amigos no pix');
      expect(bar.map((d) => d.amount), [50.0, 30.0]);
      expect(bar.every((d) => d.paymentMethod == 'pix'), isTrue);
      final one = engine.parseMulti('comprei um ps5 por 5000 cada um no pix');
      expect(one.length, 1);
      expect(one.single.amount, 5000.0);
    });
  });

  group('Item de compra sem categoria herda a do irmão; suplementos são saúde', () {
    test('"comprei X por N e Y por M": Y sem vocabulário fica com a categoria de X', () {
      for (final p in [
        'comprei detergente por 12 e esponja por 4 no pix',
        'comprei 1 vitamina c por 30 e um shake proteico por 18 no pix',
        'comprei whey por 250 e albumina por 75 no débito',
      ]) {
        final ds = engine.parseMulti(p);
        expect(ds.length, 2, reason: p);
        expect(ds[0].category, isNot('unknown'), reason: p);
        expect(ds[1].category, ds[0].category, reason: p);
        expect(ds[1].missingSlots, isNot(contains('category')), reason: p);
      }
    });

    test('lugar/serviço sem vocabulário continua perguntando a categoria', () {
      final last = engine.parseMulti('comprei 40 de ração e 25 no relojoeiro no débito').last;
      expect(last.category, 'unknown');
      expect(last.missingSlots, contains('category'));
    });

    test('vocabulário de suplementos', () {
      for (final p in [
        'gastei 80 com albumina no pix',
        'comprei creatina de 120 no pix',
        'paguei 95 no colágeno no débito',
        'comprei um pré-treino de 140 no pix',
        'gastei 60 de vitamina d no pix',
        'comprei glutamina por 110 no crédito à vista',
      ]) {
        expect(engine.parse(p).category, 'health', reason: p);
      }
    });
  });

  group('Título de ação: verbo no infinitivo vira o nome do serviço', () {
    test('lavar/cortar/consertar/revisar/trocar', () {
      for (final e in {
        'gastei 75 no dinheiro para lavar o carro': 'Lavagem do carro',
        'paguei 40 pra cortar o cabelo no pix': 'Corte do cabelo',
        'gastei 300 pra consertar a geladeira no pix': 'Conserto da geladeira',
        'paguei 250 pra revisar a moto no débito': 'Revisão da moto',
        'gastei 90 pra trocar o pneu no pix': 'Troca do pneu',
        'paguei 120 pra limpar o sofá no pix': 'Limpeza do sofá',
      }.entries) {
        expect(engine.parse(e.key).description, e.value, reason: e.key);
      }
    });

    test('quando algo foi comprado, o título é a coisa', () {
      expect(engine.parse('comprei um balde de 30 pra lavar o carro no pix').description, 'Balde');
    });
  });

  group('Mensalidade: pagamento no passado é único; recorrência só com sinal real', () {
    test('gastei/paguei … mensalidade sem "todo/vence" = pagamento de hoje, não pergunta o dia', () {
      for (final p in [
        'gastei 100 reais na mensalidade da academia no pix',
        'paguei a mensalidade da escola de 1200 no pix',
        'paguei 350 da mensalidade do inglês no débito',
        'quitei a mensalidade do clube, 90 no boleto',
        'acabei de pagar a mensalidade da natação, paguei 180 no pix',
      ]) {
        final d = engine.parse(p);
        expect(d.isRecurrent, isFalse, reason: p);
        expect(d.dueDay, isNull, reason: p);
        expect(d.missingSlots, isEmpty, reason: p);
        expect(d.dateOffsetDays, 0, reason: p);
      }
    });

    test('com data dita, é o pagamento daquele dia', () {
      final d = engine.parse('gastei 150 na mensalidade do inglês no débito ontem');
      expect(d.isRecurrent, isFalse);
      expect(d.dateOffsetDays, -1);
      expect(d.isComplete, isTrue);
    });

    test('continua recorrente com sinal de recorrência real', () {
      for (final p in [
        'pago 100 de mensalidade da academia todo dia 5 no pix',
        'paguei 100 de mensalidade da academia no pix, vence todo dia 5',
        'a mensalidade da faculdade vence dia 10, é 890 no boleto',
        'assinei a mensalidade do pilates de 200 no pix',
        'mensalidade da academia 100 no pix',
      ]) {
        expect(engine.parse(p).isRecurrent, isTrue, reason: p);
      }
    });
  });

  group('Compra parcelada com dia de pagamento não é recorrente', () {
    test('"todo dia N"/"vence dia N" com parcelas = vencimento das parcelas', () {
      for (final e in {
        'comprei um playstation 5 por 5000 parcelado em 7 vezes, para pagar todo dia 10 do mes': (5000.0, 7, 10),
        'comprei uma geladeira de 3600 em 12x no cartão, a parcela vence todo dia 15': (3600.0, 12, 15),
        'comprei sofá de 2400 no cartão em 6x pra pagar dia 20': (2400.0, 6, 20),
        'parcelei o notebook de 4200 em 10x no crédito, vence sempre no dia 5': (4200.0, 10, 5),
        'comprei uma bicicleta de 1800 em 6 vezes no cartão com vencimento todo dia 25': (1800.0, 6, 25),
      }.entries) {
        final d = engine.parse(e.key);
        expect(d.amount, e.value.$1, reason: e.key);
        expect(d.installments, e.value.$2, reason: e.key);
        expect(d.installmentDueDay, e.value.$3, reason: e.key);
        expect(d.isRecurrent, isFalse, reason: e.key);
        expect(d.dueDay, isNull, reason: e.key);
        expect(d.dateOffsetDays, 0, reason: e.key);
        expect(d.isComplete, isTrue, reason: '${e.key} → ${d.missingSlots}');
      }
      final ps5 = engine.parse('comprei um playstation 5 por 5000 parcelado em 7 vezes, para pagar todo dia 10 do mes');
      expect(ps5.installmentValue, 714.29);
    });

    test('valor da parcela: total = parcela × N, com a conta avisada', () {
      for (final e in {
        'comprei um ps5 em 7 parcelas de 714,29 no cartão': (5000.03, 7),
        'comprei uma tv no crédito em 10x, a parcela é de 350': (3500.0, 10),
        'comprei um celular em 12x de 199,90 no crédito': (2398.8, 12),
        'parcelei a cama em 5 vezes no cartão, cada parcela ficou 240': (1200.0, 5),
      }.entries) {
        final d = engine.parse(e.key);
        expect(d.amount, e.value.$1, reason: e.key);
        expect(d.installments, e.value.$2, reason: e.key);
        expect(d.assumptionNote, contains('${e.value.$2} × '), reason: e.key);
        expect(d.missingSlots, isNot(contains('split')), reason: e.key);
      }
    });

    test('total e parcela ditos juntos: vale o total, sem perguntar "qual valor"', () {
      final d = engine.parse('comprei um ps5 por 5000 em 7x de 714,29 no cartão');
      expect(d.amount, 5000.0);
      expect(d.installments, 7);
      expect(d.missingSlots, isNot(contains('split')));
    });

    test('sem parcelas continua recorrente; assinatura anual parcelada também', () {
      final gym = engine.parse('pago 120 de academia todo dia 5');
      expect(gym.isRecurrent, isTrue);
      expect(gym.dueDay, 5);
      expect(gym.installmentDueDay, isNull);
      final plan = engine.parse('assinei o plano anual da academia por 1200 em 12x no crédito, renova todo dia 5');
      expect(plan.isRecurrent, isTrue);
      expect(plan.dueDay, 5);
      expect(plan.installmentDueDay, isNull);
      final car = engine.parse('pago a parcela do carro de 1200 todo dia 10 no boleto');
      expect(car.isRecurrent, isTrue);
    });

    test('dia das parcelas dito na resposta à pergunta das parcelas', () {
      final d = engine.mergeDrafts(engine.parse('comprei uma geladeira de 3000 no crédito'), 'em 10x, pra pagar todo dia 5');
      expect(d.installments, 10);
      expect(d.installmentDueDay, 5);
      expect(d.isRecurrent, isFalse);
      expect(d.dueDay, isNull);
      expect(d.isComplete, isTrue);
    });

    test('o gate não pergunta a data pelo dia de vencimento das parcelas', () {
      final d = engine.parse('comprei sofá de 2400 no cartão em 6x pra pagar dia 20');
      expect(EntrySafetyGate.review(d).ok, isTrue);
    });

    test('gravado sem virar conta mensal de R\$ 5000', () {
      final repo = FinancialRepository();
      final d = engine.parse('comprei um playstation 5 por 5000 parcelado em 7 vezes, para pagar todo dia 10 do mes');
      final tx = repo.addTransactionFromDraft(d).single;
      expect(tx.isRecurrent, isFalse);
      expect(tx.dueDay, isNull);
      expect(tx.installments, 7);
      expect(tx.notes, 'Parcelas vencem todo dia 10');
      expect(repo.getUpcomingBills(end: DateTime.now().add(const Duration(days: 60))).where((b) => b['id'] == tx.id), isEmpty);
    });
  });

  group('5º dia útil: sábado conta, domingo e feriado não', () {
    test('novembro/2026 → 3,4,5,6,7 → dia 07 (sábado)', () {
      final d = RealtimeCalendarService.nthBusinessDay(DateTime(2026, 11), 5);
      expect(d, DateTime(2026, 11, 7));
      expect(RealtimeCalendarService().getFifthBusinessDay(DateTime(2026, 11)), DateTime(2026, 11, 7));
    });

    test('vários meses', () {
      final expected = {
        DateTime(2026, 1): DateTime(2026, 1, 7), // 1 feriado, 2 sex, 3 sáb, 5, 6, 7
        DateTime(2026, 2): DateTime(2026, 2, 6), // começa no domingo: 2..6
        DateTime(2026, 3): DateTime(2026, 3, 6), // começa no domingo: 2..6
        DateTime(2026, 4): DateTime(2026, 4, 7), // 3 = Sexta-feira Santa: 1, 2, 4, 6, 7
        DateTime(2026, 8): DateTime(2026, 8, 6), // começa no sábado: 1, 3, 4, 5, 6
        DateTime(2026, 9): DateTime(2026, 9, 5), // 7 é feriado depois: 1..5
        DateTime(2027, 5): DateTime(2027, 5, 7), // 1 = sábado e feriado, 2 dom: 3..7
      };
      for (final e in expected.entries) {
        expect(RealtimeCalendarService.nthBusinessDay(e.key, 5), e.value, reason: '${e.key.month}/${e.key.year}');
      }
    });

    test('feriado na semana empurra a contagem', () {
      // Novembro/2026 tem Finados (2, segunda); dezembro/2026 tem Natal só no
      // dia 25 — 1..5 (sábado 5).
      expect(RealtimeCalendarService.nthBusinessDay(DateTime(2026, 12), 5), DateTime(2026, 12, 5));
      // Setembro/2025: 1..6 sem feriado → 6 (sábado); 7 (domingo e feriado).
      expect(RealtimeCalendarService.nthBusinessDay(DateTime(2025, 9), 5), DateTime(2025, 9, 5));
      expect(RealtimeCalendarService.nthBusinessDay(DateTime(2025, 9), 6), DateTime(2025, 9, 6));
      expect(RealtimeCalendarService.nthBusinessDay(DateTime(2025, 9), 7), DateTime(2025, 9, 8));
    });

    test('nextNthBusinessDay usa a mesma regra', () {
      expect(RealtimeCalendarService.nextNthBusinessDay(5, referenceDate: DateTime(2026, 10, 16)), DateTime(2026, 11, 7));
      expect(RealtimeCalendarService.nextNthBusinessDay(5, referenceDate: DateTime(2026, 11, 7)), DateTime(2026, 11, 7));
    });

    test('dia bancário (boleto) continua sem sábado; Sexta-feira Santa é feriado', () {
      final cal = RealtimeCalendarService();
      expect(cal.isBusinessDay(DateTime(2026, 11, 7)), isFalse);
      expect(RealtimeCalendarService.isWorkingDay(DateTime(2026, 11, 7)), isTrue);
      expect(RealtimeCalendarService.isWorkingDay(DateTime(2026, 11, 8)), isFalse);
      expect(RealtimeCalendarService.goodFriday(2026), DateTime(2026, 4, 3));
      expect(RealtimeCalendarService.goodFriday(2027), DateTime(2027, 3, 26));
      expect(cal.isBusinessDay(DateTime(2026, 4, 3)), isFalse);
    });
  });
}
