// Rodada 3 (generalização) do construtor: regras estruturais para referência
// a lançamentos, correção sem verbo, comandos durante rascunho pendente,
// perguntas e múltiplos alvos. Cada grupo usa frases NOVAS — que não estão no
// relatório `docs/qa/findings-conversa-r2.md` nem na bateria R2 — para provar
// que a regra generaliza em vez de casar frases.
//
// O `ChatSim` (bateria antiga) espelha `_sendMessage` do chat, com o
// `CesarAssistant` real e um `FinancialRepository` de verdade.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_qa/conversation_probe_test.dart' show ChatSim;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  final now = DateTime.now();
  DateTime day(int back) => DateTime(now.year, now.month, now.day - back, 12);

  /// Repositório vazio + [seed] (ids "seed-…").
  Future<ChatSim> fresh([List<FinancialTransaction> seed = const []]) async {
    SharedPreferences.setMockInitialValues({});
    final repo = FinancialRepository();
    await repo.clearAllData();
    for (final t in seed) {
      repo.addTransaction(t);
    }
    return ChatSim(engine, repo);
  }

  FinancialTransaction seed(String id, String title, double amount, int back,
          {String category = 'expense_other', String pay = 'pix', TransactionType type = TransactionType.expense}) =>
      FinancialTransaction(id: 'seed-$id', title: title, amount: amount, type: type, category: category, paymentMethod: pay, date: day(back));

  FinancialTransaction? byId(ChatSim s, String id) => s.repo.transactions.where((t) => t.id == id).firstOrNull;
  List<FinancialTransaction> created(ChatSim s) => s.repo.transactions.where((t) => !t.id.startsWith('seed-')).toList();

  group('R2-CONV-006 / R2-FEAT-003: título = o que o usuário disse; tipo e categoria também são referência', () {
    for (final e in {
      'gastei 38 na mercearia no débito': 'Mercearia',
      'recebi 180 de gorjeta no pix': 'Gorjeta',
      'paguei 80 na ótica no pix': 'Ótica',
      'gastei 70 no boteco no pix': 'Boteco',
      'recebi 400 de bônus no pix': 'Bônus',
      'comprei um ventilador de 140 no débito': 'Ventilador',
      'jantei fora, 95 no crédito à vista': 'Jantar',
    }.entries) {
      test('"${e.key}" → título "${e.value}"', () async {
        final s = await fresh();
        s.send(e.key);
        expect(created(s).single.title, e.value);
      });
    }

    test('"apaga a lanchonete" acha o lançamento pelo nome dito', () async {
      final s = await fresh();
      s.send('paguei 22 na lanchonete no pix');
      final r = s.send('apaga a lanchonete');
      expect(r.route, 'confirm_delete');
      s.send('sim');
      expect(created(s), isEmpty);
    });

    test('"exclui a transferência" pega a transferência, não o último lançamento', () async {
      final s = await fresh();
      s.send('transferi 150 pro cofrinho no pix');
      s.send('gastei 20 na banca de revista no pix');
      s.send('outros');
      final r = s.send('exclui a transferência');
      expect(r.route, 'confirm_delete', reason: '$r');
      expect(r.text, contains('150'));
    });

    test('lançamento antigo salvo com o rótulo da categoria é achado pela categoria', () async {
      final s = await fresh([seed('old', 'supermercado / feira', 43, 3, category: 'supermarket')]);
      final r = s.send('remove a mercearia');
      expect(r.route, 'confirm_delete', reason: '$r');
      s.send('pode');
      expect(byId(s, 'seed-old'), isNull);
    });

    test('"a receita" como referência escolhe a receita mais recente', () async {
      final s = await fresh();
      s.send('recebi 180 de gorjeta no pix');
      s.send('gastei 70 no boteco no pix');
      final r = s.send('apaga a receita');
      expect(r.route, 'confirm_delete', reason: '$r');
      expect(r.text, contains('Gorjeta'));
    });
  });

  // Lançamentos antigos (fora desta conversa) para as referências.
  List<FinancialTransaction> olds() => [
        seed('lava', 'Lava Rápido Brilho', 40, 3, category: 'transport', pay: 'debit_card'),
        seed('sorvete', 'Sorveteria Gelato', 26, 5, category: 'leisure'),
        seed('ingles', 'Mensalidade Inglês', 350, 8, category: 'education', pay: 'bank_slip'),
        seed('acougue', 'Açougue do Tião', 88, 2, category: 'supermarket', pay: 'cash'),
        seed('onibus', 'Ônibus 474', 4.40, 0, category: 'transport'),
      ];

  group('R2-CONV-004/005, R2-FEAT-001: cita um lançamento + traz um campo novo = edição (sem verbo)', () {
    test('"o açougue de anteontem foi 92" (nome + data)', () async {
      final s = await fresh(olds());
      expect(s.send('o açougue de anteontem foi 92').route, 'edited');
      expect(byId(s, 'seed-acougue')!.amount, 92);
      expect(created(s), isEmpty);
    });

    test('"aquela da sorveteria foi no débito" (demonstrativo)', () async {
      final s = await fresh(olds());
      s.send('aquela da sorveteria foi no débito');
      expect(byId(s, 'seed-sorvete')!.paymentMethod, 'debit_card');
      expect(created(s), isEmpty);
    });

    test('ordem invertida com o valor antigo negado: "foi 360 a mensalidade de inglês, e não 350"', () async {
      final s = await fresh(olds());
      s.send('foi 360 a mensalidade de inglês, e não 350');
      expect(byId(s, 'seed-ingles')!.amount, 360);
      expect(created(s), isEmpty);
    });

    test('pelo valor: "o de 88 foi no pix, não em dinheiro"', () async {
      final s = await fresh(olds());
      s.send('o de 88 foi no pix, não em dinheiro');
      expect(byId(s, 'seed-acougue')!.paymentMethod, 'pix');
    });

    test('"a sorveteria agora é 28" e "o lava rápido tá errado, é 42"', () async {
      final s = await fresh(olds());
      s.send('a sorveteria agora é 28');
      s.send('o lava rápido tá errado, é 42');
      expect(byId(s, 'seed-sorvete')!.amount, 28);
      expect(byId(s, 'seed-lava')!.amount, 42);
      expect(created(s), isEmpty);
    });

    test('"a primeira foi 25" corrige o primeiro lançamento da conversa', () async {
      final s = await fresh();
      s.send('paguei 22 na lanchonete no pix');
      s.send('gastei 70 no boteco no pix');
      s.send('a primeira foi 25');
      expect(created(s).map((t) => t.amount).toSet(), {25.0, 70.0});
    });

    test('ambíguo com lançamento novo (valor novo, registro antigo, sem marca de correção) → pergunta', () async {
      final s = await fresh(olds());
      final r = s.send('o açougue foi 95');
      expect(r.route, 'ask_correction_or_new');
      expect(byId(s, 'seed-acougue')!.amount, 88, reason: 'nada muda antes da resposta');
      expect(s.send('correção').route, 'edited');
      expect(byId(s, 'seed-acougue')!.amount, 95);
      expect(created(s), isEmpty);
    });

    test('não é edição: lançamento com verbo próprio e opinião', () async {
      final s = await fresh(olds());
      s.send('o açougue tava fechado, gastei 30 na padaria no pix');
      s.send('o açougue foi ótimo');
      expect(byId(s, 'seed-acougue')!.amount, 88);
      expect(byId(s, 'seed-acougue')!.paymentMethod, 'cash');
      expect(created(s).single.amount, 30);
    });

    test('multi: pedaço que é só contexto numérico não vira lançamento', () async {
      final s = await fresh();
      final r = s.send('o conserto deu 500, o seguro cobriu 380 e eu paguei 120 no pix');
      expect(r.route, isNot('multi'));
      expect(r.route, isNot('ask_multi'));
      expect(r.draft?.amount, 120);
    });
  });

  group('R2-CONV-007 / R2-FEAT-006 / R2-CONV-008 / R2-CONV-022: comandos com referência explícita', () {
    Future<ChatSim> withPending() async {
      final s = await fresh(olds());
      s.send('gastei 38 na mercearia no débito');
      final ask = s.send('gastei 18 na quitanda no pix');
      expect(ask.route, 'ask', reason: 'a quitanda fica pendente perguntando a categoria');
      return s;
    }

    test('rascunho pendente + "exclui a mercearia" → apaga a mercearia e avisa que descartou o rascunho', () async {
      final s = await withPending();
      final r = s.send('exclui a mercearia');
      expect(r.route, 'confirm_delete');
      expect(r.text, contains('Deixei de lado'));
      s.send('sim');
      expect(created(s), isEmpty);
    });

    test('rascunho pendente + "muda o açougue pra 90" → edita o açougue', () async {
      final s = await withPending();
      expect(s.send('muda o açougue pra 90').route, 'edited');
      expect(byId(s, 'seed-acougue')!.amount, 90);
      expect(created(s).single.title, 'Mercearia');
    });

    test('rascunho pendente + "apaga a quitanda" (é o próprio rascunho) → só descarta', () async {
      final s = await withPending();
      expect(s.send('apaga a quitanda').route, 'cancel_pending');
      expect(created(s).single.title, 'Mercearia');
    });

    test('rascunho pendente + "apaga isso" continua sendo cancelamento', () async {
      final s = await withPending();
      expect(s.send('apaga isso').route, 'cancel_pending');
      expect(created(s), hasLength(1));
    });

    for (final e in {
      'joga fora o da sorveteria': 'seed-sorvete',
      'some com aquele do açougue': 'seed-acougue',
      'tira aquele de 350': 'seed-ingles',
      'elimina o lava rápido': 'seed-lava',
      'risca o 474': 'seed-onibus',
    }.entries) {
      test('"${e.key}" pede confirmação e apaga', () async {
        final s = await fresh(olds());
        final r = s.send(e.key);
        expect(r.route, 'confirm_delete', reason: '$r');
        s.send('pode apagar');
        expect(byId(s, e.value), isNull);
        expect(s.repo.transactions, hasLength(4));
      });
    }

    test('"muda o valor daquela da sorveteria pra 30"', () async {
      final s = await fresh(olds());
      s.send('muda o valor daquela da sorveteria pra 30');
      expect(byId(s, 'seed-sorvete')!.amount, 30);
    });

    test('número que é nome: "o 474 de hoje foi no débito" edita o ônibus', () async {
      final s = await fresh(olds());
      s.send('o 474 de hoje foi no débito');
      expect(byId(s, 'seed-onibus')!.paymentMethod, 'debit_card');
      expect(byId(s, 'seed-onibus')!.amount, 4.40);
    });
  });

  group('R2-FEAT-002: vários alvos numa frase, uma confirmação', () {
    test('"apaga o boteco e a lanchonete" lista os dois e apaga com "sim"', () async {
      final s = await fresh();
      s.send('paguei 22 na lanchonete no pix');
      s.send('gastei 70 no boteco no pix');
      final r = s.send('apaga o boteco e a lanchonete');
      expect(r.route, 'confirm_delete');
      expect(r.text, allOf(contains('Boteco'), contains('Lanchonete')));
      s.send('sim');
      expect(created(s), isEmpty);
    });

    test('"exclui a sorveteria e o açougue de anteontem"', () async {
      final s = await fresh(olds());
      final r = s.send('exclui a sorveteria e o açougue de anteontem');
      expect(r.route, 'confirm_delete');
      s.send('confirmo');
      expect(byId(s, 'seed-sorvete'), isNull);
      expect(byId(s, 'seed-acougue'), isNull);
    });

    test('"muda o lava rápido e a sorveteria pra crédito" edita os dois', () async {
      final s = await fresh(olds());
      expect(s.send('muda o lava rápido e a sorveteria pra crédito').route, 'edited');
      expect(byId(s, 'seed-lava')!.paymentMethod, 'credit_card');
      expect(byId(s, 'seed-sorvete')!.paymentMethod, 'credit_card');
    });

    test('um dos alvos não existe → não mexe em nada', () async {
      final s = await fresh(olds());
      final r = s.send('apaga a sorveteria e a borracharia');
      expect(r.route, 'not_found');
      expect(s.repo.transactions, hasLength(5));
    });

    test('"arroz e feijão" não é dois alvos', () async {
      final s = await fresh([seed('af', 'Arroz e feijão', 32, 1, category: 'supermarket')]);
      expect(s.send('apaga o arroz e feijão').route, 'confirm_delete');
    });
  });

  // Dados de demonstração do repositório: salário 4.500; despesas 1.948,40
  // (aluguel 1.400 boleto, Carrefour 380,50 débito, academia 119,90 crédito,
  // uber 48 pix); saldo 2.551,60; João deve 150.
  group('R2-CONV-010/011/015/016, R2-FEAT-004/005: pergunta = medida × filtro × período', () {
    const months = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
    final thisMonth = months[now.month - 1];
    final lastMonth = months[(now.month + 10) % 12];

    Future<ChatSim> demo() async {
      SharedPreferences.setMockInitialValues({});
      return ChatSim(engine, FinancialRepository());
    }

    for (final e in <String, (bool Function(String), String)>{
      'quanto foi que eu gastei no mês de $thisMonth?': ((r) => r == 'report:spending', '1.948,40'),
      'me fala quanto entrou esse mês': ((r) => r == 'report:income', '4.500'),
      'qual o total que saiu no cartão de débito?': ((r) => r == 'report:spending', '380,50'),
      'quantas vezes eu usei o uber esse mês?': ((r) => r == 'report:count', '1 lançamento'),
      'quando foi a última vez que eu paguei aluguel?': ((r) => r == 'report:lastTime', 'Aluguel'),
      'o joão ainda tá me devendo quanto?': ((r) => r == 'report:debtors', '150'),
      'tem alguém me devendo grana?': ((r) => r == 'report:debtors', 'João'),
      'sobrou alguma coisa do mês?': ((r) => r == 'report:overview', '2.551,60'),
      'gastei mais do que na semana passada?': ((r) => r == 'report:overview', 'semana'),
      'dá um resumo de como tô': ((r) => r.startsWith('report:'), ''),
      'pra onde tá indo meu dinheiro?': ((r) => r == 'report:topCategory', 'Moradia'),
      'quanto ganhei em $lastMonth?': ((r) => r == 'report:income', 'em $lastMonth'),
      'você faz o que exatamente?': ((r) => r == 'help', ''),
      'e se eu lançar errado, como arrumo?': ((r) => r == 'help', ''),
    }.entries) {
      test('"${e.key}"', () async {
        final s = await demo();
        final r = s.send(e.key);
        expect(e.value.$1(r.route), isTrue, reason: '$r');
        expect(r.text, contains(e.value.$2), reason: '$r');
        expect(created(s).where((t) => !t.id.startsWith('init-')), isEmpty, reason: 'pergunta não vira lançamento');
      });
    }

    test('follow-up que troca a medida: "quanto recebi esse mês?" ⏎ "e o que saiu?"', () async {
      final s = await demo();
      s.send('quanto recebi esse mês?');
      final r = s.send('e o que saiu?');
      expect(r.route, 'report:spending');
      expect(r.text, contains('1.948,40'));
    });

    test('pergunta sem resposta vira "ainda não sei", nunca rascunho', () async {
      final s = await demo();
      for (final q in ['qual é o melhor cartão pra usar?', 'a Carla já me pagou?', 'quem ganhou o jogo ontem?']) {
        final r = s.send(q);
        expect(r.route, anyOf('unanswered', startsWith('report:')), reason: '$q => $r');
        expect(r.draft, isNull, reason: q);
      }
      expect(s.repo.transactions.where((t) => !t.id.startsWith('init-')), isEmpty);
    });

    test('lançamento com "?" e valor continua lançamento', () async {
      final s = await demo();
      final r = s.send('gastei 42 na padaria no pix?');
      expect(r.draft?.amount, 42);
    });
  });

  group('R2-CONV-018: segundo salário no mesmo mês pergunta se é correção', () {
    Future<ChatSim> demo() async {
      SharedPreferences.setMockInitialValues({});
      return ChatSim(engine, FinancialRepository());
    }

    List<FinancialTransaction> salaries(ChatSim s) => s.repo.transactions.where((t) => t.category == 'salary').toList();

    test('"o salário chegou 4800 esse mês" ⏎ "correção" corrige o salário do mês', () async {
      final s = await demo();
      expect(s.send('o salário chegou 4800 esse mês').route, 'ask_correction_or_new');
      expect(s.send('correção').route, 'edited');
      expect(salaries(s).single.amount, 4800);
    });

    test('"o meu salário veio 4600" ⏎ "outra" registra uma entrada nova', () async {
      final s = await demo();
      expect(s.send('o meu salário veio 4600').route, 'ask_correction_or_new');
      s.send('outra');
      expect(salaries(s).map((t) => t.amount).toSet(), {4500.0, 4600.0});
    });

    test('adiantamento do salário não pergunta', () async {
      final s = await demo();
      expect(s.send('recebi o adiantamento do salário, 2000 no pix').route, isNot('ask_correction_or_new'));
    });
  });

  group('R2-CONV-019: forma de pagamento e recorrência ditas de outro jeito', () {
    for (final e in <String, (String, bool?)>{
      'Quitei o condomínio de R\$ 780,00 com boleto bancário.': ('bank_slip', null),
      'a mensalidade da escola do guri, 950, foi por boleto': ('bank_slip', null),
      'paguei o boleto da internet, 110 no pix': ('pix', null),
      'pago 49,90 mensais de academia no débito': ('debit_card', true),
    }.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.paymentMethod, e.value.$1, reason: '$d');
        if (e.value.$2 != null) expect(d.isRecurrent, e.value.$2);
      });
    }

    test('"a prestação 3 de 12" não é o valor', () {
      expect(engine.parse('paguei a prestação 3 de 12 da geladeira, 180 no boleto').amount, 180);
    });
  });

  group('R2-CONV-021: interjeição antes da correção e "não, deixa"', () {
    test('"hmm, foi anteontem" e "putz, era 46" corrigem o último', () async {
      final s = await fresh();
      s.send('gastei 64 no açougue no pix');
      expect(s.send('hmm, foi anteontem').route, 'edited');
      expect(s.send('putz, era 46').route, 'edited');
      final t = created(s).single;
      expect(t.amount, 46);
      expect(t.date.day, day(2).day);
    });

    test('rascunho pendente ⏎ "não, deixa" descarta', () async {
      final s = await fresh();
      s.send('gastei 40');
      expect(s.send('não, deixa').route, 'cancel_pending');
      expect(created(s), isEmpty);
    });
  });

  group('R2-CONV-023 / R2-CONV-020: vocabulário do dia a dia (não pergunta a categoria)', () {
    for (final e in {
      'paguei 60 na barbearia no pix': 'expense_other',
      'gastei 25 na lavanderia no pix': 'expense_other',
      'paguei 80 no lava rápido no débito': 'transport',
      'paguei 200 na clínica de fisioterapia no pix': 'health',
      'gastei 45 no rolezinho de domingo no pix': 'leisure',
      'paguei 30 no churrasquinho da esquina no pix': 'leisure',
      "fui no bob's e deu 42 no débito": 'leisure',
    }.entries) {
      test(e.key, () {
        final d = engine.parse(e.key);
        expect(d.category, e.value, reason: '$d');
        expect(d.missingSlots, isNot(contains('category')));
      });
    }
  });
}
