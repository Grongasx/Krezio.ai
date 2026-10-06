// Corretor, rodada 3 (Item 2, lote A do PLANO_CESAR.md): os 7 P0 dos achados
// docs/qa/findings-conversa-r3.md e docs/qa/findings-caos-r3.md. Cada grupo traz
// a frase do achado (reprodução) e frases NOVAS que o relatório não listava,
// para provar que a regra generalizou (skill krezio-fix-issues, "Contra overfitting").
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  group('CHAOS-R3-001 / CONV-R3-012: frase completa nova não é fundida num rascunho sem valor', () {
    // [rascunho sem valor, frase nova completa, tipo esperado da frase nova, valor]
    const cases = [
      // do achado
      ['gastei no mercado no pix', 'recebi 300 de salário no pix', 'income', 300.0],
      ['paguei o aluguel', 'recebi 4500 de salário', 'income', 4500.0],
      ['gastei no mercado no pix', 'o uber foi 30', 'expense', 30.0],
      ['a feira hoje tava ótima', 'gastei 20 na padaria no pix', 'expense', 20.0],
      // novas
      ['comprei um sapato', 'ganhei 120 de gorjeta no pix', 'income', 120.0],
      ['paguei a academia', 'transferi 80 pro meu irmão no pix', 'transfer', 80.0],
      ['gastei no posto no débito', 'a farmácia deu 45 no débito', 'expense', 45.0],
      ['o uber hoje demorou demais', 'paguei 60 no jantar no crédito à vista', 'expense', 60.0],
      ['o mercado tava lotado hoje', 'comprei uma camiseta de 70 no pix', 'expense', 70.0],
      ['paguei o condomínio', 'caiu 1200 do freela na conta', 'income', 1200.0],
      ['tô pensando no mercado de amanhã', 'gastei 35 no açougue no dinheiro', 'expense', 35.0],
    ];
    for (final c in cases) {
      test('${c[0]} ⏎ ${c[1]}', () {
        final pending = engine.parse(c[0] as String);
        expect(pending.missingSlots, contains('amount'), reason: 'o rascunho precisa estar sem valor');
        expect(engine.startsNewTransaction(pending, c[1] as String), isTrue);
        final fresh = engine.parse(c[1] as String);
        expect(fresh.intent, c[2]);
        expect(fresh.amount, c[3]);
      });
    }

    // A resposta à pergunta "quanto foi?" continua sendo resposta.
    const answers = [
      ['gastei no mercado no pix', '50'],
      ['gastei no mercado', '50 reais no pix'],
      ['paguei o aluguel', 'foi 1500 no boleto'],
      ['gastei no mercado no pix', 'o mercado deu 230'],
      ['gastei no mercado', 'gastei 80 no débito'],
      ['comprei um tênis', 'uns 300 no crédito à vista'],
      ['recebi meu salário', 'caiu 4200'],
      ['paguei o uber', 'deu 27,50 no pix'],
    ];
    for (final a in answers) {
      test('resposta: ${a[0]} ⏎ ${a[1]}', () {
        final pending = engine.parse(a[0]);
        expect(pending.missingSlots, contains('amount'));
        expect(engine.startsNewTransaction(pending, a[1]), isFalse);
        expect(engine.mergeDrafts(pending, a[1]).amount, isNotNull);
      });
    }
  });

  group('CONV-R3-001: dinheiro que chega ao usuário (de modo informal) é receita', () {
    // Regra estrutural em MoneyDirectionDetector: (1) alguém "me" + verbo de
    // dar/passar dinheiro; (2) o dinheiro como sujeito de um verbo de chegada
    // ("caiu/pingou/entrou 300"); (3) o usuário "fez/descolou/arrumou" uma
    // grana. Verbos de cobrar/vender/custar continuam despesa.
    const incoming = {
      // do achado
      'fiz uma graninha de 400 com uns bicos de eletricista': 400.0,
      'meu sogro me descolou 200 no pix': 200.0,
      // novas
      'minha tia me arrumou 150 no pix': 150.0,
      'pingou 90 de um freela na conta': 90.0,
      'entraram 350 da venda do sofá no pix': 350.0,
      'o vizinho me adiantou 500 do conserto': 500.0,
      'descolei 250 vendendo bolo no pix': 250.0,
      'fiz um extra de 180 dando aula particular': 180.0,
      'caíram 75 de cashback na conta': 75.0,
      'meu padrinho me mandou um pix de 100': 100.0,
    };
    for (final e in incoming.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.intent, 'income');
        expect(d.amount, e.value);
        expect(const {'salary', 'income_other', 'investment'}, contains(d.category));
      });
    }

    // Quem paga é o usuário: continua despesa.
    const outgoing = [
      'o mecânico me cobrou 300 no pix',
      'o cara me vendeu um tênis por 200 no pix',
      'esse curso me custou 450 no crédito à vista',
      'caiu a fatura de 900 no débito',
      'fiz uma compra de 80 no mercado no pix',
      'arrumei o carro por 600 no pix',
    ];
    for (final s in outgoing) {
      test('despesa: $s', () => expect(engine.parse(s).intent, 'expense'));
    }

    test('responder o pagamento não confirma o tipo errado (multi-turno)', () {
      final a = engine.parse('fiz uma graninha de 400 com uns bicos de eletricista');
      final merged = a.isComplete ? a : engine.mergeDrafts(a, 'pix');
      expect(merged.intent, 'income');
      expect(merged.amount, 400);
      final b = engine.parse('meu sogro me descolou 200 no pix');
      final mergedB = b.isComplete ? b : engine.mergeDrafts(b, 'presente');
      expect(mergedB.intent, 'income');
    });
  });

  group('CONV-R3-002: multi-lançamento não perde o 2º item', () {
    // Pedaço sem verbo próprio é item quando traz um valor e o nome de algo,
    // em qualquer ordem: "N de X", "X por N", "X N", "um X de N".
    const multi = {
      // do achado
      'coloquei 100 de gasolina e 30 de calibragem no débito': [100.0, 30.0],
      'comprei pão por 9 e leite por 6 no dinheiro': [9.0, 6.0],
      'almoço 32 e janta 48 no pix': [32.0, 48.0],
      'comprei um livro de 55 e um caderno de 20 no crédito à vista': [55.0, 20.0],
      // novas
      'comprei arroz por 25 e feijão por 9 no débito': [25.0, 9.0],
      'café 8 e pão de queijo 6 no pix': [8.0, 6.0],
      'comprei uma camiseta de 60 e uma bermuda de 45 no pix': [60.0, 45.0],
      'botei 50 de gasolina e 20 de ducha no pix': [50.0, 20.0],
      'pizza 70, refrigerante 12 no dinheiro': [70.0, 12.0],
      'paguei a luz por 180 e a água por 90 no boleto': [180.0, 90.0],
      'lanche 15 e sorvete 9 no débito': [15.0, 9.0],
    };
    for (final e in multi.entries) {
      test(e.key, () {
        final drafts = engine.parseMulti(e.key);
        expect(drafts.map((d) => d.amount).toList(), e.value);
        expect(drafts.every((d) => d.intent == 'expense'), isTrue);
        expect(drafts.every((d) => d.paymentMethod != 'unknown'), isTrue, reason: 'o pagamento dito no fim vale para todos');
      });
    }

    test('"no crédito à vista" dito no fim vale para os dois itens', () {
      for (final s in ['comprei um livro de 55 e um caderno de 20 no crédito à vista', 'comprei uma mochila de 120 e um estojo de 30 no crédito em 3x']) {
        final drafts = engine.parseMulti(s);
        expect(drafts.length, 2);
        expect(drafts.map((d) => d.missingSlots.contains('installments')), everyElement(isFalse), reason: s);
        expect(drafts.map((d) => d.installments).toSet().length, 1, reason: s);
      }
    });

    // Invariante: 2+ valores e só 1 lançamento ⇒ nunca salva em silêncio.
    const unsplittable = [
      'gastei 50 no mercado 30 na farmácia no pix',
      'paguei 100 de luz 80 de água no pix',
      'hoje foi 40 de uber 25 de lanche no débito',
      'gastei 120 no mercado 45 no açougue no dinheiro',
    ];
    for (final s in unsplittable) {
      test('não segmentável pergunta: $s', () {
        final drafts = engine.parseMulti(s);
        if (drafts.length >= 2) return; // segmentou: ok
        final d = engine.parse(s);
        expect(d.isComplete, isFalse);
        expect(d.clarificationPrompt, contains('valor'));
        // Responder com a frase de um item de cada vez não fica preso.
        expect(engine.startsNewTransaction(d, 'gastei 50 no mercado no pix'), isTrue);
      });
    }

    // Um valor só (ou números que não são valor): continua um lançamento completo.
    const single = {
      'comprei 2 cafés de 5 no pix': 10.0,
      'paguei 300 em 3x no crédito': 300.0,
      'comprei 3 camisetas por 90 no pix': 90.0,
      'gastei 50 no mercado às 14h no pix': 50.0,
      'paguei 70 de luz, que venceu dia 10, no pix': 70.0,
      'gastei 45 no posto 24 horas no débito': 45.0,
    };
    for (final e in single.entries) {
      test('um só: ${e.key}', () {
        final drafts = engine.parseMulti(e.key);
        expect(drafts.length, 1);
        expect(drafts.single.amount, e.value);
        expect(drafts.single.missingSlots, isNot(contains('split')));
      });
    }
  });

  group('CONV-R3-003 / FEAT-R3-004: hipótese ("se eu…", "e se…", "caso eu…") não registra', () {
    Future<(FinancialRepository, CesarAssistant)> fresh() async {
      SharedPreferences.setMockInitialValues({});
      final repo = FinancialRepository();
      await repo.clearAllData();
      return (repo, CesarAssistant(repository: repo, engine: engine));
    }

    /// Mesma ordem do chat: comando → pergunta → lançamento. Devolve a
    /// resposta do César (ou null se virou lançamento) e grava como o chat.
    Future<(AssistantReply?, int)> say(String text) async {
      final (repo, a) = await fresh();
      final before = repo.transactions.length;
      a.beginTurn();
      final cmd = a.handleCommand(text);
      if (cmd != null && cmd.rewrittenInput == null) return (cmd, repo.transactions.length - before);
      final q = a.handleQuestion(text);
      if (q != null) return (q, repo.transactions.length - before);
      final d = engine.parse(text);
      if (LocalFinancialNlpEngine.isRecordable(d)) repo.addTransactionFromDraft(d);
      return (null, repo.transactions.length - before);
    }

    test('do achado: responde a parcela e não grava', () async {
      final (r, added) = await say('se eu comprar um celular de 2000 em 10x, quanto fica por mês?');
      expect(added, 0);
      expect(r, isNotNull);
      expect(r!.text, contains('10 × R\$ 200,00'));
    });

    const withInstallments = {
      'e se eu parcelar uma geladeira de 3600 em 12x?': '12 × R\$ 300,00',
      'caso eu compre um sofá de 1500 em 5 vezes, quanto dá por mês?': '5 × R\$ 300,00',
      'quanto fica uma tv de 2400 em 6x?': '6 × R\$ 400,00',
      'se a gente comprasse uma moto de 9000 em 18 parcelas, quanto sairia?': '18 × R\$ 500,00',
    };
    for (final e in withInstallments.entries) {
      test(e.key, () async {
        final (r, added) = await say(e.key);
        expect(added, 0);
        expect(r?.text, contains(e.value));
      });
    }

    const withoutInstallments = [
      'se eu gastar 300 no mercado essa semana ainda fecho o mês no azul?',
      'e se eu pagar 800 de conserto do carro no pix?',
      'caso eu faça uma viagem de 2500, como fico?',
      'se eu tirar 400 pra um curso, vale a pena?',
      'vale a pena comprar um fone de 250 à vista?',
      'se eu fizer uma festa de 1200 no crédito, compensa?',
    ];
    for (final s in withoutInstallments) {
      test(s, () async {
        final (r, added) = await say(s);
        expect(added, 0, reason: 'hipótese nunca vira lançamento');
        expect(r, isNotNull);
      });
    }

    // Negativos obrigatórios: expressões com "se" que não são hipótese.
    const stillRecords = [
      'se eu não me engano gastei 50 no mercado no pix',
      'gastei 50 no mercado, se não me engano, no pix',
      'se não me falha a memória paguei 80 de luz no pix',
      'paguei 120 na farmácia no débito, se eu lembro bem',
      'se eu gastei 45 no posto ontem no pix, registra aí',
    ];
    for (final s in stillRecords) {
      test('continua registrando: $s', () async {
        final (r, added) = await say(s);
        expect(r?.route, isNot('hypothesis'));
        expect(added, 1);
      });
    }
  });

  // Datas relativas a hoje (o motor usa DateTime.now()); as regras são as do
  // SpokenDayParser, as mesmas do TransactionReferenceResolver.
  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  int offsetOf(DateTime d) => DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(today().year, today().month, today().day)).inDays;

  /// Dia da semana dito ao lançar = a última ocorrência, 1 a 7 dias atrás.
  int backTo(int weekday) {
    var b = (today().weekday - weekday) % 7;
    if (b == 0) b = 7;
    return -b;
  }

  /// "dia N" sem recorrência = o dia N mais recente: deste mês se N ≤ hoje,
  /// senão do mês anterior.
  int dayN(int n) {
    final t = today();
    return offsetOf(n <= t.day ? DateTime(t.year, t.month, n) : DateTime(t.year, t.month - 1, n));
  }

  /// "dd/mm" = este ano; se ainda não chegou, o ano passado.
  int ddmm(int d, int m) {
    final t = today();
    final ahead = m > t.month || (m == t.month && d > t.day);
    return offsetOf(DateTime(ahead ? t.year - 1 : t.year, m, d));
  }

  group('CHAOS-R3-002: a data dita ao lançar é usada (ou perguntada), nunca trocada por hoje', () {
    final cases = <String, int>{
      // do achado
      'gastei 50 no mercado segunda no pix': backTo(DateTime.monday),
      'gastei 50 no mercado na segunda-feira no pix': backTo(DateTime.monday),
      'gastei 50 no mercado sábado passado no pix': backTo(DateTime.saturday),
      'gastei 50 no mercado há 3 dias no pix': -3,
      'gastei 50 no mercado em 31/08 no pix': ddmm(31, 8),
      // novas
      'paguei 30 de estacionamento na quarta no débito': backTo(DateTime.wednesday),
      'comprei um livro de 40 domingo no pix': backTo(DateTime.sunday),
      'recebi 200 de freela faz 2 dias no pix': -2,
      'gastei 25 no açougue 4 dias atrás no dinheiro': -4,
      'almocei por 38 na sexta-feira no pix': backTo(DateTime.friday),
      'paguei 90 na farmácia em 03/09 no débito': ddmm(3, 9),
      'na terça eu gastei 60 no posto no débito': backTo(DateTime.tuesday),
      // o que já funcionava continua
      'gastei 50 no mercado ontem no pix': -1,
      'gastei 50 no mercado anteontem no pix': -2,
      'gastei 50 no mercado hoje no pix': 0,
      'paguei 30 pela segunda via do boleto no pix': 0,
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.missingSlots, isNot(anyOf(contains('date'), contains('split'))), reason: '${d.clarificationPrompt}');
        expect(d.dateOffsetDays, e.value);
      });
    }

    const asks = [
      'gastei 50 no mercado mês passado no pix',
      'gastei 50 no mercado amanhã no pix',
      'paguei 120 de luz depois de amanhã no pix',
      'recebi 300 de freela amanhã no pix',
    ];
    for (final s in asks) {
      test('pergunta a data: $s', () {
        final d = engine.parse(s);
        expect(d.isComplete, isFalse);
        expect(d.missingSlots, contains('date'));
      });
    }

    test('"mês passado" ⏎ "dia 15" grava no dia 15 do mês anterior', () {
      final t = today();
      final d = engine.mergeDrafts(engine.parse('gastei 80 na farmácia mês passado no pix'), 'dia 15');
      expect(d.isComplete, isTrue);
      expect(d.dateOffsetDays, offsetOf(DateTime(t.year, t.month - 1, 15)));
    });

    test('"amanhã" ⏎ "ontem": grava ontem; ⏎ "amanhã" de novo: continua perguntando', () {
      final p = engine.parse('gastei 45 no mercado amanhã no pix');
      expect(engine.mergeDrafts(p, 'ontem').dateOffsetDays, -1);
      expect(engine.mergeDrafts(p, 'ontem').isComplete, isTrue);
      expect(engine.mergeDrafts(p, 'amanhã').isComplete, isFalse);
    });
  });

  group('CHAOS-R3-003: "dia N" sem palavra de recorrência é a data de um lançamento único', () {
    // Regra: o dia N mais recente — deste mês se N ≤ hoje, senão do mês anterior.
    final once = <String, int>{
      // do achado
      'gastei 50 no mercado dia 28 no pix': dayN(28),
      'no dia 28 gastei 50 no mercado no pix': dayN(28),
      'gastei 50 no mercado no dia 5 no pix': dayN(5),
      'recebi 60 de freela dia 28 no pix': dayN(28),
      // novas
      'paguei 45 na pizzaria dia 3 no crédito à vista': dayN(3),
      'comprei um tênis de 250 no dia 12 no pix': dayN(12),
      'recebi 300 do aluguel do quarto dia 10 no pix': dayN(10),
      'o boleto do seguro foi pago dia 7, 180 no pix': dayN(7),
      'recebi meu salário de 3200 dia 5': dayN(5),
    };
    for (final e in once.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.isRecurrent, isFalse);
        expect(d.dueDay, isNull);
        expect(d.dateOffsetDays, e.value);
      });
    }

    // Com palavra de recorrência (ou presente habitual) continua recorrente.
    const recurring = {
      'pago 50 de academia todo dia 10 no pix': 10,
      'a netflix vence dia 15, 39,90 no crédito': 15,
      'meu salário de 3000 cai dia 5': 5,
      'pago 120 de internet dia 10 no boleto': 10,
      'mensalidade da escola de 800 dia 8 no boleto': 8,
    };
    for (final e in recurring.entries) {
      test('recorrente: ${e.key}', () {
        final d = engine.parse(e.key);
        expect(d.isRecurrent, isTrue);
        expect(d.dueDay, e.value);
        expect(d.dateOffsetDays, 0, reason: 'dia de vencimento não é a data do lançamento');
      });
    }
  });

  group('CHAOS-R3-004 / CHAOS-R3-005: nome dito não casa só pela categoria em outra data', () {
    final now = DateTime(2026, 9, 29, 12); // terça
    FinancialTransaction tx(String id, String title, double amount, DateTime date, String cat) => FinancialTransaction(
        id: id, title: title, amount: amount, type: TransactionType.expense, category: cat, paymentMethod: 'pix', date: date);

    Future<(FinancialRepository, CesarAssistant)> seeded() async {
      SharedPreferences.setMockInitialValues({});
      final repo = FinancialRepository();
      await repo.clearAllData();
      for (final t in [
        tx('feira-sab', 'Feira', 80, DateTime(2026, 9, 26, 10), 'supermarket'),
        tx('sacolao-ter', 'Sacolão', 60, DateTime(2026, 9, 22, 10), 'supermarket'),
        tx('padaria-seg', 'Padaria', 25, DateTime(2026, 9, 28, 8), 'supermarket'),
        tx('posto-seg', 'Posto', 150, DateTime(2026, 9, 28, 9), 'transport'),
        tx('uber-dom', 'Uber', 30, DateTime(2026, 9, 27, 20), 'transport'),
        tx('mercado-ago', 'Mercado', 200, DateTime(2026, 8, 31, 10), 'supermarket'),
      ]) {
        repo.addTransaction(t);
      }
      return (repo, CesarAssistant(repository: repo, engine: engine, now: () => now));
    }

    String state(FinancialRepository r) =>
        (r.transactions.map((t) => '${t.id}:${t.amount}:${t.paymentMethod}:${t.date.day}').toList()..sort()).join(',');

    /// Chat order: command → question → (new entry). Returns the reply and
    /// whether a new entry would have been parsed as recordable.
    AssistantReply? say(CesarAssistant a, String text) {
      a.beginTurn();
      final c = a.handleCommand(text);
      if (c != null && c.rewrittenInput == null) return c;
      return a.handleQuestion(text);
    }

    // [frase, título que deve ser sugerido]
    const edits = [
      // do achado
      ['muda a feira de segunda pra 90', 'Feira'],
      ['a feira de segunda foi 90', 'Feira'],
      ['a feira de segunda foi no débito', 'Feira'],
      ['muda a feira de ontem pra 1', 'Feira'],
      ['muda o mercado de segunda pra 10', 'Mercado'],
      ['muda o uber de segunda pra 40', 'Uber'],
      ['o uber de segunda foi 40', 'Uber'],
      // novas
      ['troca o valor do sacolão de segunda pra 33', 'Sacolão'],
      ['o sacolão de ontem foi 40', 'Sacolão'],
      ['corrige o uber de ontem pra 18', 'Uber'],
      ['a feira do dia 28 foi no dinheiro', 'Feira'],
      ['altera a data do uber de segunda pra hoje', 'Uber'],
    ];
    for (final e in edits) {
      test('não edita outro registro: ${e[0]}', () async {
        final (repo, a) = await seeded();
        final before = state(repo);
        final r = say(a, e[0]);
        expect(state(repo), before, reason: 'nada pode mudar sem confirmação');
        expect(r, isNotNull, reason: 'responde "não achei…", não lança nem edita em silêncio');
        expect(r!.route, 'not_found');
        expect(r.text, contains(e[1]));
        expect(r.text, isNot(contains('Padaria')));
        expect(r.text, isNot(contains('Posto')));
      });
    }

    const deletes = [
      'apaga a feira de segunda',
      'exclui a feira do dia 28',
      'apaga a feira de ontem',
      'apaga o mercado de segunda',
      'apaga o uber de segunda',
      'deleta o sacolão de ontem',
      'remove a feira de hoje',
    ];
    for (final s in deletes) {
      test('não oferece outro registro para apagar: $s', () async {
        final (repo, a) = await seeded();
        final before = state(repo);
        final r = say(a, s)!;
        expect(r.route, isNot('confirm_delete'));
        expect(r.text, isNot(contains('Padaria')));
        expect(r.text, isNot(contains('Posto')));
        say(a, 'sim');
        expect(state(repo), before);
      });
    }

    test('controle: com nome e data certos, edita; sem nome de registro, a categoria acha e CONFIRMA mostrando o item', () async {
      final (repo, a) = await seeded();
      expect(say(a, 'muda a feira de sábado pra 90')!.route, isNot('not_found'));
      expect(repo.transactions.firstWhere((t) => t.id == 'feira-sab').amount, 90);
      // "gasolina" não é nome de nenhum registro: o Posto (transporte) de
      // segunda é o candidato, mas — decisão do usuário de 2026-10-01 (7e) —
      // nome que não está no título sempre confirma antes ("é esse?").
      final r = say(a, 'muda a gasolina de segunda pra 160')!;
      expect(r.text, contains('Posto'), reason: 'mostra o item');
      expect(repo.transactions.firstWhere((t) => t.id == 'posto-seg').amount, 150, reason: 'nada muda antes do "sim"');
      say(a, 'sim');
      expect(repo.transactions.firstWhere((t) => t.id == 'posto-seg').amount, 160);
      expect(say(a, 'apaga o uber de domingo')!.route, 'confirm_delete');
    });
  });
}
