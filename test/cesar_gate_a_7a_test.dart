// Corretor, Portão do lote A, etapa 7a (PLANO_CESAR.md): direção do dinheiro e
// hipóteses — achados de docs/qa/findings-aceite-lote-a.md (ACC-A-*) e
// docs/qa/findings-caos-lote-a.md (CHAOS-A-*). As frases daqui são NOVAS (não
// estão nos achados nem nas baterias): provam que as regras por papel/gramática
// generalizam, e que o desconhecido vira pergunta em vez de lançamento errado.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/hypothesis_detector.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/ai/money_direction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  Future<CesarAssistant> assistant() async {
    SharedPreferences.setMockInitialValues({});
    final repo = FinancialRepository();
    await repo.clearAllData();
    return CesarAssistant(repository: repo, engine: engine);
  }

  /// Receita, ou a pergunta "entrou ou saiu?" — nunca despesa em silêncio.
  void expectIncomeOrAsk(String p) {
    final d = engine.parse(p);
    final asked = d.missingSlots.contains('type');
    expect(d.intent == 'income' || asked, isTrue, reason: '$p → ${d.intent} ${d.missingSlots}');
    expect(d.amount, isNotNull, reason: p);
  }

  group('ACC-A-001 / CHAOS-A-005: venda é entrada', () {
    const sales = {
      'vendi meu videogame antigo por 900 no pix': 900.0,
      'vendemos a mesa de jantar por 650 no dinheiro': 650.0,
      'vendi um tênis usado por 120 no débito': 120.0,
      'apurei 340 na feirinha de artesanato no dinheiro': 340.0,
      'passamos o sofá velho pra frente por 300 no pix': 300.0,
      'passei a guitarra pra frente por 800 no pix': 800.0,
      'faturei 1200 com as encomendas de bolo no pix': 1200.0,
    };
    for (final e in sales.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.intent, 'income', reason: '${d.intent} ${d.category}');
        expect(d.amount, e.value);
      });
    }
  });

  group('ACC-A-001 / ACC-A-011: verbo sem direção conhecida pergunta; o que foi feito pra ganhar decide', () {
    // O que foi feito para ganhar (gerúndio de trabalho, gorjeta, comissão) = entrada.
    for (final p in [
      'puxei 350 fazendo entrega de moto no pix',
      'bati 180 de comissão ontem no pix',
      'levantei 90 de gorjeta no sábado no pix',
      'consegui 260 dando aula particular no pix',
      'descolei 180 lavando carro no pix',
    ]) {
      test('entrada: $p', () {
        final d = engine.parse(p);
        expect(d.intent, 'income', reason: '${d.intent} ${d.missingSlots} ${d.clarificationPrompt}');
        expect(d.amount, isNotNull);
      });
    }
    // Nada diz se entrou ou saiu: pergunta, não grava.
    for (final p in ['catei 70 no pix', 'levantei 2000 no banco', 'tirei 300 no caixa eletrônico no pix']) {
      test('pergunta: $p', () {
        final d = engine.parse(p);
        expect(d.missingSlots, contains('type'), reason: '${d.intent} ${d.missingSlots}');
        expect(d.isComplete, isFalse);
        expect(d.clarificationPrompt, contains('entrou'));
      });
    }
    // Gíria de gasto com o que foi comprado dito e o classificador seguro: não pergunta.
    for (final p in ['derreti 90 na pizzaria no pix', 'detonei 60 no cinema no débito']) {
      test('continua despesa: $p', () {
        final d = engine.parse(p);
        expect(d.intent, 'expense');
        expect(d.missingSlots, isNot(contains('type')));
      });
    }
    test('"entrou" como resposta completa a receita', () {
      final merged = engine.mergeDrafts(engine.parse('catei 70 no pix'), 'entrou');
      expect(merged.intent, 'income');
      expect(merged.isComplete, isTrue);
    });
  });

  group('ACC-A-002: cobrança que "cai/chega/vem" é despesa; "cai dia N" de conta é vencimento', () {
    for (final p in [
      'chegou a conta de gás de 95 no boleto',
      'veio uma taxa de 12 no débito',
      'caiu a anuidade do cartão, 480 no crédito à vista',
      'tomei uma multa de 130 por excesso de velocidade no pix',
      'ganhamos uma multa de 88 do condomínio no pix',
    ]) {
      test('despesa: $p', () {
        final d = engine.parse(p);
        expect(d.intent, 'expense', reason: '${d.intent} ${d.category}');
        expect(MoneyDirectionDetector.detect(p), MoneyDirection.outgoing);
      });
    }
    test('a netflix vence todo dia 8, 44,90 no crédito', () {
      final d = engine.parse('a netflix vence todo dia 8, 44,90 no crédito');
      expect(d.intent, 'expense');
      expect(d.amount, 44.90);
      expect(d.dueDay, 8);
    });
    test('a academia cai dia 10, 99 no débito', () {
      final d = engine.parse('a academia cai dia 10, 99 no débito');
      expect(d.intent, 'expense');
      expect(d.dueDay, 10);
    });
    test('controle: meu salário cai dia 5, 3200 no pix continua receita', () {
      expect(engine.parse('meu salário cai dia 5, 3200 no pix').intent, 'income');
    });
  });

  group('CHAOS-A-004: "me" + verbo — quem paga é quem faz o infinitivo; conta entregue é cobrança', () {
    for (final p in [
      'minha mãe me pediu pra pagar 70 da farmácia no pix',
      'o professor me fez comprar um livro de 120 no pix',
      'o síndico me mandou a cobrança de 350 do condomínio',
      'meu chefe me passou o boleto de 200',
      'o mecânico me enviou o orçamento de 900',
      'a operadora me mandou a fatura de 180',
    ]) {
      test('despesa: $p', () {
        final d = engine.parse(p);
        expect(d.intent, 'expense', reason: '${d.intent} ${d.missingSlots}');
      });
    }
    // "me" + verbo que não é de entregar dinheiro: o "me" pode ser a vítima — nunca receita.
    for (final p in ['me furtaram 150 no ônibus', 'me levaram 80 na saidinha do banco', 'me aplicaram um golpe de 300 no pix']) {
      test('nunca receita: $p', () {
        final d = engine.parse(p);
        expect(d.intent == 'income' && !d.missingSlots.contains('type'), isFalse, reason: '${d.intent} ${d.missingSlots}');
      });
    }
    test('coisa com preço entregue a mim ("me empurraram um plano de 60") pergunta', () {
      final d = engine.parse('me empurraram um plano de 60 no pix');
      expect(d.missingSlots, contains('type'));
    });
    // Controles: dinheiro entregue a mim continua entrada.
    for (final p in [
      'meu irmão me mandou 150 no pix',
      'a vizinha me passou 80 de volta no pix',
      'o joão me enviou um pix de 45',
      'minha avó me mandou um dinheiro pro aniversário, 200 no pix',
    ]) {
      test('entrada: $p', () {
        expect(engine.parse(p).intent, 'income');
      });
    }
  });

  group('CHAOS-A-019 / CHAOS-A-023: "me devolveram/descontaram N" tem valor e direção', () {
    test('rascunho de despesa ⏎ "me reembolsaram 40" é uma receita nova', () {
      final pending = engine.parse('paguei a farmácia no pix');
      expect(pending.missingSlots, contains('amount'));
      expect(engine.startsNewTransaction(pending, 'me reembolsaram 40'), isTrue);
      final fresh = engine.parse('me reembolsaram 40');
      expect(fresh.intent, 'income');
      expect(fresh.amount, 40);
    });
    test('rascunho ⏎ "o joão me pagou 60" é receita nova', () {
      final pending = engine.parse('gastei no posto no débito');
      expect(engine.startsNewTransaction(pending, 'o joão me pagou 60'), isTrue);
    });
    for (final e in {
      'me descontaram 120 do salário por falta': 120.0,
      'me cobraram 25 de tarifa no débito': 25.0,
      'me debitaram 19,90 de seguro do cartão': 19.90,
    }.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.intent, 'expense');
        expect(d.amount, e.value);
      });
    }
  });

  group('ACC-A-009 / CHAOS-A-001: hipótese em qualquer posição não vira lançamento', () {
    for (final p in [
      'supondo que eu compre uma geladeira de 3500, fico no vermelho?',
      'vamos supor que eu gaste 250 num show',
      'compro o ingresso de 180 no pix se ainda tiver lugar',
      'vou pagar 90 no dentista se ele me encaixar amanhã',
      'se a reforma custar 4000, ainda dá?',
      'pagaria 300 num curso de inglês',
      'na hipótese de a viagem sair 2500, quanto sobra?',
      'se no fim do mês sobrar 400 eu invisto no pix',
    ]) {
      test(p, () async {
        expect(HypothesisDetector.detect(p), isNotNull);
        final a = await assistant();
        a.beginTurn();
        final r = a.handleQuestion(p);
        expect(r?.route, 'hypothesis');
        expect(a.repository.transactions, isEmpty);
      });
    }
  });

  group('ACC-A-010 / CHAOS-A-017: fato no passado com "se/caso" em outra oração registra', () {
    const facts = {
      'comprei 45 de ração no pix, se o gato gostar compro mais': 'expense',
      'paguei 60 de estacionamento no débito, caso precise do recibo tá comigo': 'expense',
      'recebi 700 do aluguel no pix, se atrasar de novo eu cobro multa': 'income',
      'gastei 25 no açougue no dinheiro caso alguém pergunte': 'expense',
      'registra 40 de padaria no pix se não for incômodo': 'expense',
      'paguei 200 pro contador do caso da empresa no pix': 'expense',
      'gastei 90 com o veterinário no pix, em caso de retorno é grátis': 'expense',
      'se quiser conferir depois, ganhei 150 de bônus no pix': 'income',
    };
    for (final e in facts.entries) {
      test(e.key, () async {
        expect(HypothesisDetector.detect(e.key), isNull);
        final a = await assistant();
        a.beginTurn();
        expect(a.handleQuestion(e.key)?.route, isNot('hypothesis'));
        expect(engine.parse(e.key).intent, e.value);
      });
    }
    // "caso"/"se" que não é conjunção, sem verbo no passado: também não é hipótese.
    for (final p in ['o caso do vizinho custou 300 no pix', 'pra ela se sentir segura comprei um cadeado de 40']) {
      test('não é hipótese: $p', () => expect(HypothesisDetector.detect(p), isNull));
    }
  });

  group('CHAOS-A-002: rascunho de hipótese não é completado', () {
    for (final (first, answer) in [
      ('se a maria me devolver 80', 'no pix'),
      ('compraria 70 de roupa se estivesse em promoção', 'no débito'),
      ('caso eu pague 150 de conserto', 'dinheiro'),
    ]) {
      test('$first ⏎ $answer', () {
        final merged = engine.mergeDrafts(engine.parse(first), answer);
        expect(LocalFinancialNlpEngine.isRecordable(merged), isFalse, reason: '${merged.intent} ${merged.amount}');
      });
    }
    test('hipótese como resposta não completa o rascunho', () {
      final pending = engine.parse('gastei no mercado no pix');
      final merged = engine.mergeDrafts(pending, 'e se fosse 200?');
      expect(LocalFinancialNlpEngine.isRecordable(merged), isFalse);
      expect(merged.missingSlots, pending.missingSlots);
    });
  });

  group('CHAOS-A-003: hipótese com lote pendente responde e mantém o lote', () {
    for (final q in ['e se fosse no crédito?', 'se eu pagar no débito quanto fica?', 'supondo que seja no pix, quanto sobra?']) {
      test(q, () async {
        final batch = engine.parseMulti('paguei 40 no uber e 25 no ifood');
        expect(batch.length, 2);
        expect(batch.every((d) => !d.isComplete), isTrue);
        final merged = engine.mergeMultiDrafts(batch, q);
        expect(merged.where(LocalFinancialNlpEngine.isRecordable), isEmpty);
        final a = await assistant();
        a.beginTurn();
        expect(a.hypothesisReply(q)?.route, 'hypothesis');
      });
    }
  });

  group('ACC-A-018: receita hipotética mostra o efeito no saldo; o valor dito é usado', () {
    for (final p in [
      'se eu ganhar 1200 de bônus, como fico?',
      'e se o cliente me pagar 900?',
      'imagina se eu recebesse 2000 de restituição',
    ]) {
      test(p, () async {
        final a = await assistant();
        a.beginTurn();
        final r = a.handleQuestion(p);
        expect(r?.route, 'hypothesis');
        expect(r!.text, isNot(contains('Posso comprar')));
        expect(r.text, contains('Se entrarem'));
        expect(a.repository.transactions, isEmpty);
      });
    }
    test('imagina se eu gastasse 350 num fone usa os 350', () async {
      final a = await assistant();
      a.beginTurn();
      final r = a.handleQuestion('imagina se eu gastasse 350 num fone');
      expect(r?.route, 'hypothesis');
      expect(r!.text, contains('350'));
      expect(r.text, isNot(contains('Me diga o valor')));
    });
  });
}
