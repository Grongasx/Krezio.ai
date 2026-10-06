// Corretor, Portão do lote A, etapa 7c (PLANO_CESAR.md): o EntrySafetyGate —
// um portão único por onde passa todo lançamento antes de ser gravado
// (direção, números, data, intenção) — e as regras gerais que ele cobra.
// Achados: docs/qa/findings-aceite-lote-a-r2.md (ACC-B-*) e
// docs/qa/findings-caos-lote-a-r2.md (CHAOS-B-*). Além da frase do achado,
// cada grupo tem frases NOVAS (não estão nos achados nem nas baterias), e o
// gate tem testes próprios por checagem, com controles contra falso positivo.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/entry_safety_gate.dart';
import 'package:krezio_ai/ai/hypothesis_detector.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  int offsetTo(DateTime d) => DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(today().year, today().month, today().day)).inDays;

  /// Dias até o último [weekday] (1–7 dias atrás).
  int lastWeekday(int weekday) {
    var back = (today().weekday - weekday) % 7;
    if (back == 0) back = 7;
    return -back;
  }

  /// O [weekday] da semana passada (segunda a domingo).
  int weekdayOfLastWeek(int weekday) {
    final monday = today().subtract(Duration(days: today().weekday - 1 + 7));
    return offsetTo(monday.add(Duration(days: weekday - 1)));
  }

  /// "dia N": o mais recente.
  int dayN(int n) => offsetTo(n <= today().day ? DateTime(today().year, today().month, n) : DateTime(today().year, today().month - 1, n));

  /// Resposta [text] a um rascunho pendente, como o chat decide.
  FinancialTransactionDraft turn(FinancialTransactionDraft pending, String text) =>
      engine.startsNewTransaction(pending, text) ? engine.parse(text) : engine.mergeDrafts(pending, text);

  /// Gravaria um lançamento com esse tipo? (completo e gravável)
  bool records(FinancialTransactionDraft d, String type) => LocalFinancialNlpEngine.isRecordable(d) && d.intent == type;

  /// Ou grava com o tipo certo, ou pergunta "entrou ou saiu?" — nunca o tipo trocado.
  void expectTypeOrAsk(String p, String type, {double? amount}) {
    final d = engine.parse(p);
    final asked = d.missingSlots.contains('type');
    expect(asked || d.intent == type, isTrue, reason: '$p → ${d.intent} ${d.amount} ${d.missingSlots} ${d.clarificationPrompt}');
    if (amount != null) expect(d.amount, amount, reason: p);
  }

  /// Ou grava na data [offset], ou pergunta a data — nunca outra data.
  void expectDateOrAsk(String p, int offset) {
    final d = engine.parse(p);
    if (d.missingSlots.contains('date')) return;
    expect(d.dateOffsetDays, offset, reason: '$p → ${d.missingSlots} ${d.clarificationPrompt}');
  }

  FinancialTransactionDraft draft(String raw, {String intent = 'expense', double? amount, int offset = 0, Set<String> settled = const {}}) =>
      FinancialTransactionDraft(
        intent: intent,
        intentConfidence: 1,
        category: 'supermarket',
        paymentMethod: 'pix',
        amount: amount,
        dateOffsetDays: offset,
        description: 'Teste',
        rawText: raw,
        latencyMs: 0,
        isComplete: true,
        missingSlots: const [],
        settledChecks: settled,
      );

  // ───────────────────────────── o gate, por checagem ─────────────────────────────

  group('EntrySafetyGate: direção', () {
    test('marcador de entrada × rascunho de despesa → "entrou ou saiu?"', () {
      final v = EntrySafetyGate.review(draft('a firma me devolveu 70 da gasolina', amount: 70));
      expect(v.check, GateCheck.direction);
      expect(v.slot, 'type');
    });
    test('marcador de saída × rascunho de receita → pergunta', () {
      final v = EntrySafetyGate.review(draft('paguei 70 na oficina', intent: 'income', amount: 70));
      expect(v.check, GateCheck.direction);
    });
    test('controle: direção coerente passa', () {
      expect(EntrySafetyGate.review(draft('paguei 70 na oficina', amount: 70)).ok, isTrue);
      expect(EntrySafetyGate.review(draft('o cliente me pagou 70', intent: 'income', amount: 70)).ok, isTrue);
    });
    test('controle: já respondido ("type" settled) não pergunta de novo', () {
      expect(EntrySafetyGate.review(draft('a firma me devolveu 70', amount: 70, settled: {'type'})).ok, isTrue);
    });
    test('desconto não é receita: pergunta quanto pagou e vira despesa', () {
      final d = draft('ganhei 30 de desconto na farmácia', intent: 'income', amount: 30);
      final v = EntrySafetyGate.review(d);
      expect(v.check, GateCheck.discount);
      final out = v.applyTo(d);
      expect(out.intent, 'expense');
      expect(out.amount, isNull);
      expect(out.missingSlots, contains('amount'));
      expect(out.settledChecks, contains('type'));
    });
  });

  group('EntrySafetyGate: números', () {
    test('2º valor monetário não explicado → split', () {
      final v = EntrySafetyGate.review(draft('gastei 40 na feira 25 na farmácia', amount: 40));
      expect(v.check, GateCheck.numbers);
      expect(v.slot, 'split');
    });
    test('dois números colados para um valor → "qual dos dois?"', () {
      final v = EntrySafetyGate.review(draft('a janta deu 70 80 reais', amount: 80));
      expect(v.check, GateCheck.numbers);
      expect(v.question, contains('qual foi o valor certo'));
    });
    test('"há N dias" nunca multiplica o valor', () {
      final v = EntrySafetyGate.review(draft('há 4 dias paguei a taxa de 30', amount: 120, offset: -4));
      expect(v.check, GateCheck.numbers);
    });
    test('controle: contagem × preço explicada passa', () {
      expect(EntrySafetyGate.review(draft('comprei 4 sucos de 6', amount: 24)).ok, isTrue);
    });
    for (final p in [
      'paguei 300 do aluguel do box 12',
      'paguei 50 de estacionamento na vaga 31',
      'comprei um tênis 42 por 199',
      'paguei a 4ª parcela de 90',
      'gastei 70 no Bar Esquina 22',
      'gastei 45 com o carregador 3 em 1',
    ]) {
      test('controle (identificador/ordinal/nome não é valor): $p', () {
        final value = p.contains('199') ? 199.0 : (p.contains('300') ? 300.0 : (p.contains('90') ? 90.0 : (p.contains('70') ? 70.0 : (p.contains('45') ? 45.0 : 50.0))));
        expect(EntrySafetyGate.review(draft(p, amount: value)).ok, isTrue, reason: EntrySafetyGate.review(draft(p, amount: value)).question);
      });
    }
  });

  group('EntrySafetyGate: data', () {
    test('marcador de tempo que não virou a data → pergunta', () {
      final v = EntrySafetyGate.review(draft('ontem gastei 40 no mercado', amount: 40, offset: 0));
      expect(v.check, GateCheck.date);
      expect(v.slot, 'date');
    });
    test('controle: a data resolvida vem do marcador', () {
      expect(EntrySafetyGate.review(draft('ontem gastei 40 no mercado', amount: 40, offset: -1)).ok, isTrue);
    });
    test('marcador vago → pergunta', () {
      expect(EntrySafetyGate.review(draft('gastei 40 no mercado esses dias', amount: 40)).check, GateCheck.date);
    });
    test('"hoje" só vence sozinho', () {
      expect(EntrySafetyGate.review(draft('hoje vi que gastei 40 ontem', amount: 40, offset: 0)).check, GateCheck.date);
      expect(EntrySafetyGate.review(draft('hoje gastei 40 no mercado', amount: 40, offset: 0)).ok, isTrue);
    });
    test('controle: nome com palavra de data e vencimento recorrente não são data', () {
      expect(EntrySafetyGate.review(draft('gastei 40 na Padaria Amanhã', amount: 40)).ok, isTrue);
      expect(EntrySafetyGate.review(draft('gastei 40 na rua 13 de maio', amount: 40)).ok, isTrue);
      expect(EntrySafetyGate.review(draft('pago 40 todo dia 10', amount: 40)).ok, isTrue);
    });
    test('controle: a resposta mais recente é a que vale (turnos)', () {
      expect(EntrySafetyGate.review(draft('gastei no açougue dia 3 + 40 hoje', amount: 40, offset: 0)).ok, isTrue);
    });
    test('data respondida (settled) não é perguntada de novo', () {
      expect(EntrySafetyGate.review(draft('gastei 40 no mercado esses dias', amount: 40, settled: {'date'})).ok, isTrue);
    });
  });

  group('EntrySafetyGate: intenção', () {
    test('plano/intenção não é lançamento', () {
      final d = draft('pretendo gastar 90 na feira', amount: 90);
      final v = EntrySafetyGate.review(d);
      expect(v.check, GateCheck.intent);
      expect(LocalFinancialNlpEngine.isRecordable(v.applyTo(d)), isFalse);
    });
    test('controle: fato no passado passa', () {
      expect(EntrySafetyGate.review(draft('gastei 90 na feira', amount: 90)).ok, isTrue);
    });
  });

  group('O gate vale para todos os caminhos (parse, merge, lote, dívida)', () {
    test('parse: frase com 2 valores nunca é gravada como 1', () {
      expect(engine.parse('gastei 40 na feira 25 na farmácia no pix').isComplete, isFalse);
    });
    test('merge: a data dita no rascunho e não usada é perguntada depois da resposta', () {
      final d = turn(engine.parse('domingão paguei o lava-jato no pix'), '45');
      expect(d.missingSlots.contains('date') || d.dateOffsetDays == lastWeekday(DateTime.sunday), isTrue, reason: '${d.dateOffsetDays} ${d.missingSlots}');
    });
    test('lote: valor que nenhum item levou não some', () {
      final multi = engine.parseMulti('gastei 30 no bar e 20 no táxi 15 na gorjeta no pix');
      final amounts = multi.map((d) => d.amount).toList();
      expect(multi.length >= 3 || multi.any((d) => !d.isComplete), isTrue, reason: '$amounts');
    });
    test('dívida: duas pessoas pagando não é um pagamento de dívida só', () {
      expect(DebtPaymentParser.parse('recebi 80 da bia e 40 do caio no pix'), isNull);
      expect(DebtPaymentParser.parse('recebi 80 da bia no pix'), isNotNull);
    });
  });

  // ───────────────────────────── direção ─────────────────────────────

  group('ACC-B-001: marcador de entrada vence o rótulo de despesa', () {
    for (final p in [
      'caiu a restituição do imposto de renda 1340',
      'entrou o reembolso do plano de saúde 210 no pix',
      'a empresa reembolsou 85 de pedágio',
      'transferência de 150 do meu irmão',
      'meu primo repassou 300 do aluguel pra mim no pix',
      'chegou a restituição de 760 no pix',
      'a seguradora estornou 120 da franquia',
    ]) {
      test(p, () => expectTypeOrAsk(p, 'income'));
    }
    test('"recebi … da diária de <profissão>": o usuário é quem recebe', () {
      for (final p in ['recebi 350 da diaria de pedreiro há 10 dias, foi pix', 'recebi 200 pela diária de servente no pix']) {
        final d = engine.parse(p);
        expect(d.intent, 'income', reason: p);
      }
      expect(engine.parse('recebi 350 da diaria de pedreiro há 10 dias, foi pix').dateOffsetDays, -10);
    });
    test('controle: pagar o profissional continua despesa', () {
      expect(engine.parse('paguei 200 da diária do pedreiro no pix').intent, 'expense');
    });
  });

  group('ACC-B-002: "todo mês pago N … dia D" é despesa recorrente', () {
    for (final p in [
      'todo mês pago 150 da escolinha de futebol do menino dia 10 no pix',
      'todo mês pago 90 da aula de natação dia 15 no pix',
      'mensalmente pago 230 do curso de inglês dia 7 no boleto',
      'pago 60 por mês da academia todo dia 20 no débito',
      'todo mês a gente paga 120 do plano dia 5 no pix',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.intent, 'expense', reason: d.clarificationPrompt);
        expect(d.isRecurrent, isTrue);
      });
    }
  });

  group('ACC-B-012: quem cobra/vende/desconta é saída', () {
    const cases = {
      'o mecânico levou 280 pelo serviço do freio': 280.0,
      'o encanador cobrou 150 pelo conserto no pix': 150.0,
      'a farmácia me vendeu um remédio por 45 no pix': 45.0,
      'descontaram 55 do meu salário por causa do atraso': 55.0,
      'descontaram 30 do meu vale por causa da falta': 30.0,
      'o banco descontou 12 de tarifa': 12.0,
      'o borracheiro levou 40 no pix': 40.0,
    };
    for (final e in cases.entries) {
      test(e.key, () => expectTypeOrAsk(e.key, 'expense', amount: e.value));
    }
  });

  group('ACC-B-013: dinheiro "com <alguém>" sem direção → "entrou ou saiu?"', () {
    for (final p in [
      'fiz um rolo de 200 com meu primo',
      'troquei 100 com o vizinho',
      'mexi 70 com o cartão do meu pai',
      'rolou 120 com o fornecedor',
      'troquei 50 com a vizinha',
      'rolou 300 com o sócio',
      'zerei 60 com o joão',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.missingSlots, contains('type'), reason: '${d.intent} ${d.clarificationPrompt}');
      });
    }
    test('controle: verbo de gasto com companhia não pergunta', () {
      expect(engine.parse('gastei 50 com o uber no pix').missingSlots, isNot(contains('type')));
    });
  });

  group('CHAOS-B-006: venda, herança e pagamento ao usuário são entrada', () {
    for (final p in [
      'fiz uma venda de 58 na banca no débito',
      'fechei uma venda de 320 no pix',
      'realizei uma venda de 45 no dinheiro',
      'herdei 2000 do meu tio no pix',
      'herdei 5000 da minha avó na banca no débito',
      'me pagaram 140 pela diária de pedreiro no pix',
      'dia 9 tirei 85 vendendo trufa no dinheiro',
      'dia 7 tirei 60 vendendo bolo no pix',
    ]) {
      test(p, () => expectTypeOrAsk(p, 'income'));
    }
  });

  group('CHAOS-B-019: desconto ≠ receita; cashback = receita', () {
    for (final p in ['ganhei 30 de desconto na farmácia no pix', 'consegui 50 de desconto no sofá no pix', 'ganhei um desconto de 15 no mercado no pix']) {
      test(p, () {
        final d = engine.parse(p);
        expect(records(d, 'income'), isFalse, reason: d.clarificationPrompt);
        expect(d.intent, isNot('income'));
      });
    }
    test('o valor pago na resposta grava como despesa, sem perguntar o tipo', () {
      final d = turn(engine.parse('ganhei 30 de desconto na farmácia no pix'), '120');
      expect(records(d, 'expense'), isTrue, reason: '${d.missingSlots} ${d.clarificationPrompt}');
      expect(d.amount, 120.0);
    });
    for (final p in ['ganhei 30 de cashback no pix', 'recebi o estorno de 80 no pix']) {
      test('controle: $p', () => expect(engine.parse(p).intent, 'income'));
    }
  });

  group('CHAOS-B-021 (falso positivo): "<verbo> N pro <pessoa>" é saída óbvia', () {
    for (final p in [
      'devolvi 80 pro joão no pix',
      'repassei 120 pro meu irmão no pix',
      'enviei 200 pra minha filha no pix',
      'adiantei 300 pro encanador no pix',
      'repassei 300 pra minha mãe no pix',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.missingSlots, isNot(contains('type')), reason: d.clarificationPrompt);
        expect(d.intent, isNot('income'));
      });
    }
  });

  // ───────────────────────────── números ─────────────────────────────

  group('ACC-B-006: dois números para um item → pergunta', () {
    for (final p in [
      'o mercado deu 80 90 reais sei la no pix',
      'a pizza deu 60 70 reais no pix',
      'gastei uns 40 a 50 no bar no pix',
      'o conserto saiu 300 ou 350 no pix',
      'paguei entre 100 e 120 de luz no pix',
      'a feira deu tipo 45 50 no dinheiro',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.isComplete, isFalse, reason: '${d.amount}');
      });
    }
    const controls = {'gastei 50 3 dias atrás na farmácia no pix': 50.0, 'gastei no dia 4 90 no petshop no pix': 90.0};
    for (final e in controls.entries) {
      test('controle: ${e.key}', () {
        final d = engine.parse(e.key);
        expect(d.amount, e.value);
        expect(d.missingSlots, isNot(contains('split')));
      });
    }
  });

  group('ACC-B-007 / ACC-B-010: identificador depois de substantivo não é valor', () {
    const cases = {
      'paguei 300 de aluguel do box 12 no shopping no pix': 300.0,
      'gastei 25 de estacionamento na vaga 40 no pix': 25.0,
      'paguei 180 na consulta da sala 1204 no pix': 180.0,
      'paguei 75 de frete pro cep 04567-000 no pix': 75.0,
      'paguei 130 do licenciamento da placa BRA-2019 no pix': 130.0,
      'comprei um galaxy s23 de 512gb por 3800 em 10x no crédito': 3800.0,
      'paguei 60 do quiosque do lote 8 no pix': 60.0,
      'paguei 25 de frete pro cep 01310-100 no pix': 25.0,
      'paguei 120 na consulta do consultório 1102 no pix': 120.0,
      'comprei um iphone 15 pro max de 256gb por 5200 em 12x no crédito': 5200.0,
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.amount, e.value, reason: d.clarificationPrompt);
        expect(d.missingSlots, isNot(contains('split')), reason: d.clarificationPrompt);
        expect(engine.parseMulti(e.key), hasLength(1));
      });
    }
  });

  group('CHAOS-B-022 (falso positivo): split só com 2 valores monetários de fato', () {
    const cases = {
      'paguei 380 no pneu aro 14 no pix': 380.0,
      'comprei 2 pão de queijo por 9 no pix': 9.0,
      'peguei 3 cerveja por 27 no pix': 27.0,
      'paguei a 2ª parcela de 175 do sofá no pix': 175.0,
      'comprei a camisa 10 do flamengo por 260 no pix': 260.0,
      'comprei 3 coxinha por 15 no pix': 15.0,
      'paguei a 3ª parcela de 220 do notebook no pix': 220.0,
      'comprei a camisa 9 do corinthians por 280 no pix': 280.0,
      'gastei 60 com o shampoo 2 em 1 no pix': 60.0,
      'gastei 85 no Restaurante Sexta-Feira 13 no pix': 85.0,
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.amount, e.value, reason: d.clarificationPrompt);
        expect(d.missingSlots, isNot(contains('split')), reason: d.clarificationPrompt);
      });
    }
    test('controle: "comprei uma camisa 50 no pix" — o número é o preço', () {
      expect(engine.parse('comprei uma camisa 50 no pix').amount, 50.0);
    });
    test('controle: dois preços de verdade ainda perguntam', () {
      expect(engine.parse('gastei 50 no mercado 30 na farmácia no pix').isComplete, isFalse);
    });
  });

  group('CHAOS-B-005: "há/faz/tem N dias" é data, nunca multiplica o valor', () {
    const cases = {
      'há três dias cobrei a consulta de 47 do paciente no débito': (47.0, -3),
      'faz dois dias paguei a diária de 80 do hotel no pix': (80.0, -2),
      'faz seis dias veio a conta de água de 85 no crédito à vista': (85.0, -6),
      'faz quatro dias paguei a conta de luz de 130 no pix': (130.0, -4),
      'tem 5 dias que paguei o ingresso de 60 no pix': (60.0, -5),
      '3 dias atrás paguei a taxa de 25 no pix': (25.0, -3),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.amount, e.value.$1);
        expect(d.dateOffsetDays, e.value.$2);
      });
    }
    test('controle: meses pagos de uma vez continuam multiplicando (decisão pendente nº 1)', () {
      expect(engine.parse('paguei 3 meses de academia de 100 no pix').amount, 300.0);
    });
  });

  group('CHAOS-B-007: cada valor vira um lançamento (ou pergunta)', () {
    const cases = {
      '23 açougue 14 padaria no pix': [23.0, 14.0],
      '12 pão 8 leite no dinheiro': [12.0, 8.0],
      '30 gasolina 15 lavagem no débito': [30.0, 15.0],
      'recebi 260 do joão e 9 da carla no pix': [260.0, 9.0],
      'recebi 100 da ana e 50 do pedro no pix': [100.0, 50.0],
      'ganhei 40 do meu avô e 20 da minha tia no pix': [40.0, 20.0],
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final multi = engine.parseMulti(e.key);
        if (multi.length >= 2) {
          expect(multi.map((d) => d.amount).toList()..sort(), [...e.value]..sort());
        } else {
          expect(multi.single.isComplete, isFalse);
        }
      });
    }
    test('dívida: "recebi N do X e M da Y" não é consumido por um pagamento só', () {
      expect(DebtPaymentParser.parse('recebi 260 do joão e 9 da carla no pix'), isNull);
    });
  });

  // ───────────────────────────── datas ─────────────────────────────

  group('ACC-B-003: marcador de tempo convertido (ou perguntado), nunca hoje em silêncio', () {
    final cases = <String, int>{
      'domingão gastei 90 no churras no pix': lastWeekday(DateTime.sunday),
      'sabadão torrei 120 no bar no pix': lastWeekday(DateTime.saturday),
      'sextona gastei 70 na pizzaria no pix': lastWeekday(DateTime.friday),
      'no dia vinte e cinco paguei 60 de uber no pix': dayN(25),
      'no dia doze paguei 99 de internet no pix': dayN(12),
      'tem uns 3 dias paguei 65 de gás no pix': -3,
      'tem uns 4 dias paguei 30 de farmácia no pix': -4,
      'faz uns cinco dias comprei um fone de 80 no pix': -5,
    };
    for (final e in cases.entries) {
      test(e.key, () => expectDateOrAsk(e.key, e.value));
    }
  });

  group('ACC-B-004: "semana passada na terça" = a terça da semana passada', () {
    final cases = <String, int>{
      'semana passada na terça paguei 80 no eletricista no pix': weekdayOfLastWeek(DateTime.tuesday),
      'na quinta da semana passada gastei 64 no mercado no pix': weekdayOfLastWeek(DateTime.thursday),
      'semana passada, na sexta, paguei 40 de uber no pix': weekdayOfLastWeek(DateTime.friday),
      'semana passada no sábado gastei 150 na feira no débito': weekdayOfLastWeek(DateTime.saturday),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.dateOffsetDays, e.value, reason: '${d.missingSlots} ${d.clarificationPrompt}');
      });
    }
  });

  group('CHAOS-B-024: marcador vago ou "semana passada" sozinha → pergunta o dia', () {
    for (final p in [
      'gastei 47 no sacolão no começo do mês no pix',
      'gastei 47 no sacolão esses dias no pix',
      'paguei 23 outro dia pro encanador no débito',
      'gastei 47 no sacolão semana passada no pix',
      'gastei 35 no açougue no início do mês no pix',
      'paguei 60 de gás um dia desses no pix',
      'comprei um livro de 45 dia desses no pix',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.missingSlots, contains('date'), reason: '${d.dateOffsetDays} ${d.clarificationPrompt}');
      });
    }
  });

  group('ACC-B-005 / CHAOS-B-003: rua/loja com nome de data não é data', () {
    for (final p in [
      'gastei 70 na rua 25 de março no pix',
      'gastei 90 numa loja da avenida 7 de setembro no pix',
      'comprei na 25 de março 150 no pix',
      'paguei 40 de estacionamento na avenida 9 de julho no pix',
      'comprei um vestido de 130 na 25 de março no pix',
      'gastei 22 na padaria da praça 15 de novembro no pix',
      'almocei 35 num restaurante da rua 7 de setembro no pix',
      'gastei 50 na Loja 13 de Maio no pix',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.dateOffsetDays, 0, reason: d.clarificationPrompt);
        expect(d.missingSlots, isNot(contains('date')));
      });
    }
    test('a data dita junto com o endereço vale', () {
      final d = engine.parse('dia 12/09 a cliente me transferiu 85 na Loja 25 de Março no dinheiro');
      final y = today().month > 9 || (today().month == 9 && today().day >= 12) ? today().year : today().year - 1;
      expect(d.dateOffsetDays, offsetTo(DateTime(y, 9, 12)));
    });
  });

  group('CHAOS-B-004 / CHAOS-B-023: numeração, tamanho e placar "d/m" não são data', () {
    for (final p in [
      'paguei 85 na aula 5/8 do curso no pix',
      'gastei 47 na sessão 4/6 do pilates no pix',
      'o jogo terminou 3/1 e gastei 85 no bar no pix',
      'paguei 60 na sessão 3/10 da fisioterapia no pix',
      'gastei 40 na rodada 2/5 do campeonato no pix',
      'o jogo acabou 2/1 e gastei 70 no bar no pix',
      'comprei um tênis 40/41 por 260 no pix',
      'comprei uma chuteira 41/42 por 300 no pix',
      'paguei 260 no plantão 12/12 do hospital no pix',
      'gastei 18 no Café Amanhã no pix',
      'gastei 30 na Padaria Hoje no pix',
      'paguei 30 no estacionamento da praça 15 de novembro no pix',
    ]) {
      test(p, () {
        final d = engine.parse(p);
        expect(d.dateOffsetDays, 0, reason: d.clarificationPrompt);
        expect(d.missingSlots, isNot(contains('date')), reason: d.clarificationPrompt);
      });
    }
    test('controle: "no dia 5/9" é data', () {
      final d = engine.parse('gastei 50 no dia 5/9 no pix');
      expect(d.dateOffsetDays == 0 && !d.missingSlots.contains('date'), isFalse);
    });
  });

  group('CHAOS-B-002: "hoje" só vence se for o único marcador', () {
    final cases = <String, int>{
      'hoje lembrei que gastei 50 no mercado ontem no pix': -1,
      'só hoje vi que paguei 80 de luz anteontem no pix': -2,
      'ontem gastei 50 no mercado, hoje tô sem grana, no pix': -1,
      'só hoje percebi que paguei 35 de uber anteontem no pix': -2,
      'hoje caiu a ficha: torrei 90 no bar ontem no pix': -1,
      'hj vi no extrato que gastei 70 na farmácia no domingo no débito': lastWeekday(DateTime.sunday),
      'hoje gastei 30 no mercado no pix': 0,
      'se ontem foi puxado, hoje foi pior: paguei 120 de luz no pix': 0,
    };
    for (final e in cases.entries) {
      test(e.key, () => expectDateOrAsk(e.key, e.value));
    }
  });

  group('CHAOS-B-008: data dita uma vez para o lote (", tudo <data>")', () {
    final cases = <String, int>{
      'açougue 23; padaria 14 no dinheiro, tudo no dia 21': dayN(21),
      'gastei 23 no açougue + 14 na padaria no pix, tudo anteontem': -2,
      'gastei 23 no açougue e mais 14 na padaria no crédito à vista, tudo ontem cedo': -1,
      'gastei 30 no bar e 20 no táxi no pix, tudo anteontem': -2,
      'paguei 50 de luz e 80 de água no boleto, foi tudo ontem': -1,
      'cinema 40, pipoca 25 no débito, tudo no sábado': lastWeekday(DateTime.saturday),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final multi = engine.parseMulti(e.key);
        expect(multi.length, 2);
        for (final d in multi) {
          expect(d.dateOffsetDays, e.value, reason: d.description);
        }
      });
    }
  });

  group('CHAOS-B-009: a data da resposta vence a do rascunho; futura → pergunta', () {
    test('gastei no sacolão no dia 20 ⏎ 47 hoje', () {
      final d = turn(engine.parse('gastei no sacolão no dia 20 no pix'), '47 hoje');
      expect(records(d, 'expense'), isTrue);
      expect(d.dateOffsetDays, 0);
    });
    test('paguei o eletricista na segunda ⏎ foi 150 ontem', () {
      final d = turn(engine.parse('paguei o eletricista na segunda no pix'), 'foi 150 ontem');
      expect(d.dateOffsetDays, -1);
    });
    test('comprei ração dia 3 ⏎ deu 89 anteontem', () {
      final d = turn(engine.parse('comprei ração dia 3 no pix'), 'deu 89 anteontem');
      expect(d.dateOffsetDays, -2);
    });
    test('paguei a lanchonete quinta avenida ⏎ deu 1350 ontem à noite', () {
      final d = turn(engine.parse('paguei a lanchonete quinta avenida no pix'), 'deu 1350 ontem à noite');
      expect(records(d, 'expense'), isTrue, reason: '${d.missingSlots} ${d.clarificationPrompt}');
      expect(d.dateOffsetDays, -1);
    });
    // "dd/mm" ainda por vir na resposta: pergunta, mesmo com data no rascunho.
    for (final (first, answer) in [
      ('paguei a lanchonete quinta avenida no pix', '58 dia {f}'),
      ('gastei no sacolão no dia 20 no pix', '47 dia {f}'),
      ('comprei ração dia 3 no pix', 'deu 89 em {f}'),
    ]) {
      test('resposta com dd/mm futuro pergunta: $first ⏎ $answer', () {
        final f = today().add(const Duration(days: 45));
        final d = turn(engine.parse(first), answer.replaceAll('{f}', '${f.day}/${f.month}'));
        expect(d.isComplete, isFalse);
        expect(d.missingSlots, contains('date'));
      });
    }
    for (final a in ['foi 58 amanhã', '58 depois de amanhã', '150 semana que vem']) {
      test('resposta com data futura pergunta: $a', () {
        final d = turn(engine.parse('paguei o eletricista na segunda no pix'), a);
        expect(d.isComplete, isFalse);
        expect(d.missingSlots, contains('date'));
      });
    }
  });

  group('CHAOS-B-017: "quinta avenida" é rua, não quinta-feira', () {
    test('paguei a lanchonete quinta avenida ⏎ 27', () {
      final d = turn(engine.parse('paguei a lanchonete quinta avenida no pix'), '27');
      expect(d.dateOffsetDays, 0);
    });
    test('gastei 30 na pizzaria quinta avenida no pix', () => expect(engine.parse('gastei 30 na pizzaria quinta avenida no pix').dateOffsetDays, 0));
    test('controle: "na quinta" continua quinta-feira', () {
      expect(engine.parse('gastei 30 na pizzaria na quinta no pix').dateOffsetDays, lastWeekday(DateTime.thursday));
    });
  });

  // ───────────────────────────── recorrência ─────────────────────────────

  group('ACC-B-014: "todo (santo) dia N cai X" mantém o X', () {
    const cases = {
      'todo santo dia 20 cai 1200 da aposentadoria na minha conta': (1200.0, 20),
      'todo dia 5 cai 800 da pensão no pix': (800.0, 5),
      'todo santo dia 10 entra 1500 do salário na conta': (1500.0, 10),
      'todo dia 25 cai 450 do aluguel do quartinho no pix': (450.0, 25),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.amount, e.value.$1, reason: d.clarificationPrompt);
        expect(d.intent, 'income');
        expect(d.isRecurrent, isTrue);
        expect(d.dueDay, e.value.$2);
      });
    }
  });

  // ───────────────────────────── hipótese / intenção ─────────────────────────────

  group('ACC-B-011 / CHAOS-B-001: intenção e hipótese não gravam', () {
    for (final p in [
      'to pensando em comprar uma air fryer de 450, será que rola?',
      'no caso de eu pagar 800 no dentista fico com quanto',
      'caso a minha mae precise de 500 eu consigo mandar?',
      'quero saber se dá pra torrar 250 no rodizio sabado',
      'pretendo gastar 250 no sacolão no pix',
      'quero comprar uma bike de 1500 no pix',
      'vou gastar uns 200 no mercado no pix',
      'assim que cair 4500 de salário eu pago o aluguel',
      'na eventualidade de eu gastar 85 no pix',
      // novas
      'tô pensando em trocar o celular por um de 2000, será que dá?',
      'no caso de a gente gastar 600 na viagem, sobra?',
      'caso o meu chefe atrase o salário eu consigo pagar o aluguel de 1200?',
      'queria saber se dá pra gastar 300 no presente',
      'estou planejando gastar 400 no mercado do mês',
      'quero comprar um notebook de 3500 no crédito',
      'em caso de eu pagar 90 de multa no pix',
      'assim que cair o pagamento de 3000 eu quito o cartão',
      'se rolar um desconto pago 70 no pix',
    ]) {
      test(p, () {
        expect(HypothesisDetector.detect(p), isNotNull);
        expect(LocalFinancialNlpEngine.isRecordable(engine.parse(p)), isFalse);
      });
    }
    test('cadeia: a resposta não completa a intenção', () {
      final d = turn(engine.parse('na eventualidade de eu gastar 85 no pix'), 'sacolão');
      expect(LocalFinancialNlpEngine.isRecordable(d) && d.amount == 85, isFalse);
    });
    for (final p in [
      'quero registrar que gastei 30 no mercado no pix',
      'vou te contar: paguei 50 de luz no pix',
      'o joão me deve 200 e paga quando receber',
    ]) {
      test('controle (não é intenção): $p', () => expect(HypothesisDetector.detect(p), isNull));
    }
  });

  group('CHAOS-B-015: fato no passado com "se/caso" de comentário grava', () {
    for (final p in [
      'acabei de pagar 47 no sacolão no pix, se precisar te mando o comprovante',
      'a conta do bar ficou em 118 no pix, se quiser divido com vc',
      'tive um gasto de 58 com remédio no pix, se for preciso guardo a nota',
      'o cliente me pagou 900 no pix, se quiser confere no extrato',
      'acabei de gastar 60 no mercado no pix, se quiser confere',
      'a janta ficou em 95 no pix, se quiser racho com você',
      'tive uma despesa de 40 com remédio no pix, caso precise da nota',
      'o inquilino me pagou 1200 no pix, se quiser vê no extrato',
    ]) {
      test(p, () {
        expect(HypothesisDetector.detect(p), isNull);
        final d = engine.parse(p);
        expect(d.intent, p.contains('me pagou') ? 'income' : 'expense', reason: d.clarificationPrompt);
      });
    }
  });

  group('Regressões do gate (7c): ele lê o que o motor leu e a data que a notificação diz', () {
    // "dando aula/plantão" é o que foi feito pra ganhar (gerúndio de radical curto).
    for (final p in [
      'consegui 260 dando aula particular no pix',
      'arranjei 120 dando aula de violão no pix',
      'bati 300 dando consultoria no pix',
      'levantei 90 dando banho em cachorro no pix',
      'tirei 200 dando plantão no hospital no pix',
    ]) {
      test('entrada: $p', () {
        final d = engine.parse(p);
        expect(records(d, 'income'), isTrue, reason: '${d.intent} ${d.missingSlots} ${d.clarificationPrompt}');
      });
    }
    test('controle: verbo sem direção e sem trabalho continua perguntando', () {
      expect(engine.parse('catei 70 no pix').missingSlots, contains('type'));
    });

    // Notificação de banco traz a data da compra: é ela que vale (o gate
    // perguntava "quando foi?" porque o lançamento ia pra hoje).
    String daysAgo(int n) {
      final d = today().subtract(Duration(days: n));
      return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
    }

    for (final (p, back) in [
      ('Compra aprovada no seu Nubank Mastercard: R\$ 45,00 em PADARIA SOL ${daysAgo(5)} às 08:10', 5),
      ('Compra aprovada no cartao Itau final 1234: R\$ 32,50 em FARMACIA PAGUE MENOS ${daysAgo(2)} 14:22', 2),
      ('Compra aprovada no seu Nubank Mastercard: R\$ 19,90 em CINEMARK', 0),
    ]) {
      test('notificação: $p', () {
        final d = engine.parse(p);
        expect(LocalFinancialNlpEngine.isRecordable(d), isTrue, reason: '${d.missingSlots} ${d.clarificationPrompt}');
        expect(d.dateOffsetDays, -back);
      });
    }

    // Erro de digitação corrigido pelo motor vale para o gate: "salrio cai
    // todo dia 5" é o salário caindo, não uma conta vencendo.
    for (final p in ['meu salrio cai todo dia 10', 'meu slario cai todo dia 5', 'meu salaro cai todo dia 20 no pix']) {
      test('salário com erro: $p', () {
        final d = engine.parse(p);
        expect(d.intent, 'income');
        expect(d.missingSlots, isNot(contains('type')), reason: d.clarificationPrompt);
        final m = engine.mergeDrafts(d, 'R\$ 3.200,00');
        expect(m.isComplete, isTrue, reason: '${m.missingSlots} ${m.clarificationPrompt}');
        expect(m.intent, 'income');
        expect(m.amount, 3200.0);
      });
    }
    // "dia 28/8" é a data dd/mm, não o "dia 28" deste mês (falso positivo de data).
    for (final (tpl, back) in [
      ('gastei 25 no dia {d} no pix', 34),
      ('paguei 40 dia {d} na farmácia no pix', 12),
      ('comprei pão dia {d} por 9 no débito', 47),
    ]) {
      test('dia dd/mm: $tpl (-$back)', () {
        final dt = today().subtract(Duration(days: back));
        final p = tpl.replaceAll('{d}', '${dt.day}/${dt.month}');
        final d = engine.parse(p);
        expect(d.missingSlots, isNot(contains('date')), reason: '$p → ${d.clarificationPrompt}');
        expect(d.dateOffsetDays, -back, reason: p);
      });
    }
    // "e mais 23 na padaria" é mais um valor (só "mais de/que N" compara) —
    // inclusive quando a frase chega com outro rascunho pendente (vai por parse).
    for (final p in [
      'gastei 47 no açougue e mais 23 na padaria no dinheiro',
      'no dia 17: gastei 37 no açougue mais 23 na padaria',
      'paguei 60 e mais 10 de gorjeta no pix',
    ]) {
      test('dois valores com "mais": $p', () {
        final d = engine.parse(p);
        expect(LocalFinancialNlpEngine.isRecordable(d), isFalse, reason: '${d.amount} ${d.clarificationPrompt}');
        expect(d.missingSlots, contains('split'));
      });
    }
    test('controle: "mais de 20 em carne" compara, não é outro valor', () {
      expect(engine.parse('gastei 50 no mercado mais de 20 em carne no pix').missingSlots, isNot(contains('split')));
    });

    // Saída óbvia com uma palavra de tempo no meio (CHAOS-B-021).
    for (final p in ['devolvi 1350 anteontem pro joão no dinheiro', 'repassei 200 ontem pra minha irmã no pix', 'adiantei 300 hoje pro pedreiro no pix']) {
      test('saída: $p', () {
        final d = engine.parse(p);
        expect(d.intent, 'expense');
        expect(d.missingSlots, isNot(contains('type')), reason: d.clarificationPrompt);
      });
    }

    // "hoje" no verbo que carrega o valor é a data do lançamento; os outros
    // marcadores falam de outra coisa (CHAOS-B-002 continua: "hoje lembrei que…").
    for (final p in [
      'hoje cedo repassei 14 pra minha mãe no açougue domingo no pix',
      'hoje paguei 40 no bar sexta no pix',
      'esquece o que eu falei ontem, hoje gastei 30 na feira no pix',
      'o mercado que era 150 semana passada hoje deu 187, paguei no débito',
      'a pizza que custou 60 sábado hoje saiu 75 no pix',
    ]) {
      test('"hoje" no valor vence: $p', () {
        final d = engine.parse(p);
        expect(d.missingSlots, isNot(contains('date')), reason: d.clarificationPrompt);
        expect(d.dateOffsetDays, 0);
      });
    }
    test('controle: "hoje faz 3 dias que paguei" é há 3 dias', () {
      expect(engine.parse('hoje faz 3 dias que paguei 40 no mercado no pix').dateOffsetDays, -3);
    });

    // "tem N anos" de um sujeito é idade, não data (a "tem 3 dias" do verbo continua data).
    for (final (p, off) in [
      ('meu carro tem 15 anos e ontem deu problema, paguei 380 no mecânico no pix', -1),
      ('minha filha tem 8 anos e paguei 120 na escola dela ontem no pix', -1),
      ('o prédio tem 40 anos, gastei 90 de condomínio extra no pix', 0),
      ('paguei a conta de luz de 90 tem 3 dias no pix', -3),
    ]) {
      test('idade × data: $p', () {
        final d = engine.parse(p);
        expect(d.missingSlots, isNot(contains('date')), reason: d.clarificationPrompt);
        expect(d.dateOffsetDays, off);
      });
    }

    // Recusar sem valor responde a pergunta; não é plano (com valor continua não-evento).
    for (final p in ['não quero parcelar', 'nem vou parcelar', 'não quero pagar juros']) {
      test('recusa não é hipótese: $p', () => expect(HypothesisDetector.detect(p), isNull));
    }
    for (final p in ['não vou gastar 300 no mercado', 'nem quero gastar 100 no bar', 'não pretendo pagar 50 de taxa']) {
      test('recusa com valor não grava: $p', () {
        expect(LocalFinancialNlpEngine.isRecordable(engine.parse(p)), isFalse);
        expect(HypothesisDetector.detect(p), isNotNull);
      });
    }

    // Um "+" do usuário não é separador de turnos do gate: a frase inteira é um turno.
    for (final p in ['gastei 14 no açougue + 66 na padaria no débito', 'paguei 30 de luz + 45 de água no pix', 'lanche 12 + suco 8 no dinheiro']) {
      test('"+" na frase: $p', () {
        final d = engine.parse(p);
        expect(LocalFinancialNlpEngine.isRecordable(d), isFalse, reason: '${d.amount} ${d.clarificationPrompt}');
      });
    }

    // Dois dias para dois valores: escolhido um valor, a data é perguntada.
    test('ontem 9 no chaveiro e hoje 1350 na banca ⏎ custou 260 → pergunta o dia', () {
      final d = engine.parse('ontem gastei 9 no chaveiro e hoje 1350 na banca no pix');
      expect(d.missingSlots, contains('split'));
      final m = engine.mergeDrafts(d, 'custou 260');
      expect(LocalFinancialNlpEngine.isRecordable(m), isFalse);
      expect(m.missingSlots, contains('date'));
    });

    // Saída óbvia com data entre o valor e "pro <pessoa>" (CHAOS-B-021).
    for (final p in [
      'devolvi 118 dia 28 do mês passado pro joão no pix',
      'repassei 200 na sexta pro meu irmão no pix',
      'adiantei 300 semana passada pro pedreiro no pix',
      'adiantei 37 ontem à noite pro pedreiro no dinheiro',
    ]) {
      test('saída com data no meio: $p', () {
        final d = engine.parse(p);
        expect(d.intent, 'expense');
        expect(d.missingSlots, isNot(contains('type')), reason: d.clarificationPrompt);
      });
    }

    // Lido como um lançamento só (chat com rascunho pendente), o que o leitor
    // de lote separa em vários pergunta — nunca guarda um valor e perde o outro.
    for (final p in ['175 açougue 9 padaria no dinheiro', '23 açougue 14 padaria no pix', 'gastei 30 no mercado e 20 na farmácia no pix']) {
      test('vários itens via parse: $p', () {
        final d = engine.parse(p);
        expect(LocalFinancialNlpEngine.isRecordable(d), isFalse, reason: '${d.amount} ${d.clarificationPrompt}');
        expect(d.missingSlots, contains('split'));
        expect(engine.parseMulti(p).length, 2);
      });
    }
    test('com rascunho pendente, frase de vários itens pergunta', () {
      final pending = engine.parse('paguei o chaveiro no pix');
      final d = turn(pending, '175 açougue 9 padaria no dinheiro');
      expect(LocalFinancialNlpEngine.isRecordable(d), isFalse);
    });

    test('controle: conta que vence todo dia N continua despesa', () {
      expect(engine.parse('o aluguel vence todo dia 10').intent, 'expense');
    });
  });
}
