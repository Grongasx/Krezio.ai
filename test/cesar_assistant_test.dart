import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives [CesarAssistant] the way the chat does: every message starts a
/// turn, commands are tried first, then questions, and anything else is a
/// new entry parsed by the engine and saved (then reported back with
/// [CesarAssistant.recordCreated]).
class Conversation {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  Conversation(this.engine, this.repo) : assistant = CesarAssistant(repository: repo, engine: engine);

  AssistantReply? send(String input) {
    var text = input;
    engine.setCustomCategories(repo.customCategoryNames);
    assistant.beginTurn();
    final cmd = assistant.handleCommand(text);
    if (cmd != null && cmd.rewrittenInput == null) return cmd;
    if (cmd != null) text = cmd.rewrittenInput!;
    final q = assistant.handleQuestion(text);
    if (q != null) return q;
    final draft = engine.parse(text);
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      final ids = repo.addTransactionFromDraft(draft).map((t) => t.id).toList();
      assistant.recordCreated(ids);
    }
    return null;
  }

  List<FinancialTransaction> get created => repo.transactions.where((t) => !t.id.startsWith('seed-')).toList();
  FinancialTransaction byTitle(String sub) => repo.transactions.firstWhere((t) => t.title.toLowerCase().contains(sub));
  bool has(String sub) => repo.transactions.any((t) => t.title.toLowerCase().contains(sub));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 10);
  final yesterday = today.subtract(const Duration(days: 1));

  /// Empty repository plus [seed] records (ids "seed-…").
  Future<Conversation> fresh([List<FinancialTransaction> seed = const []]) async {
    SharedPreferences.setMockInitialValues({});
    final repo = FinancialRepository();
    await repo.clearAllData();
    for (final t in seed) {
      repo.addTransaction(t);
    }
    return Conversation(engine, repo);
  }

  FinancialTransaction seed(String id, String title, double amount, DateTime date, {String category = 'transport', String pay = 'pix'}) =>
      FinancialTransaction(id: 'seed-$id', title: title, amount: amount, type: TransactionType.expense, category: category, paymentMethod: pay, date: date);

  group('Correção do último lançamento em linguagem livre (FEAT-003/004, CONV-018/019, CHAOS-010)', () {
    for (final phrase in ['não, foi 45', 'nao foi 45', 'ops, era 45', 'corrige pra 45', 'o valor certo é 45', 'na verdade foi 45', 'muda pra 45']) {
      test('"$phrase" muda o valor e diz o que mudou', () async {
        final c = await fresh();
        c.send('gastei 50 no mercado no pix');
        final r = c.send(phrase)!;
        expect(r.route, 'edited');
        expect(r.text, contains('o valor de R\$ 50,00 para R\$ 45,00'));
        expect(c.created.single.amount, 45);
      });
    }

    for (final e in {
      'esse era lazer': 'leisure',
      'coloca em lazer': 'leisure',
      'muda a categoria pra transporte': 'transport',
      'na verdade foi farmácia': 'health',
      'não é mercado, é farmácia': 'health',
    }.entries) {
      test('"${e.key}" muda a categoria para ${e.value}', () async {
        final c = await fresh();
        c.send('gastei 50 no mercado no pix');
        final r = c.send(e.key)!;
        expect(r.route, 'edited');
        expect(c.created.single.category, e.value);
        expect(r.text, contains('a categoria de Supermercado para'));
      });
    }

    test('"na verdade foi farmácia" também renomeia o lançamento', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      c.send('na verdade foi farmácia');
      expect(c.created.single.title, 'Farmácia');
    });

    test('data: "na verdade foi ontem", "foi anteontem"', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      final r = c.send('na verdade foi ontem')!;
      expect(DateTime(c.created.single.date.year, c.created.single.date.month, c.created.single.date.day),
          DateTime(yesterday.year, yesterday.month, yesterday.day));
      expect(r.text, contains('a data de hoje'));
      c.send('foi anteontem');
      expect(today.difference(c.created.single.date).inDays, anyOf(1, 2));
    });

    test('tipo: "na verdade foi uma entrada" vira receita (sem categoria de despesa)', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      final r = c.send('na verdade foi uma entrada')!;
      expect(c.created.single.type, TransactionType.income);
      expect(c.created.single.category, 'income_other');
      expect(r.text, contains('o tipo de despesa para receita'));
    });

    test('"era receita, não gasto" e "era transferência"', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      c.send('era receita, não gasto');
      expect(c.created.single.type, TransactionType.income);
      c.send('era transferência');
      expect(c.created.single.type, TransactionType.transfer);
    });

    test('correções encadeadas: "na verdade foi 45" ⏎ "e foi no débito"', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      c.send('na verdade foi 45');
      final r = c.send('e foi no débito')!;
      expect(r.text, contains('cartão de débito'));
      expect(c.created.single.amount, 45);
      expect(c.created.single.paymentMethod, 'debit_card');
    });

    test('"na verdade foi no crédito em 3x" mantém o valor', () async {
      final c = await fresh();
      c.send('comprei um fone de 300 no pix');
      c.send('na verdade foi no crédito em 3x');
      expect(c.created.single.amount, 300);
      expect(c.created.single.paymentMethod, 'credit_card');
      expect(c.created.single.installments, 3);
    });

    test('"edita o último lançamento" mostra o resumo e pergunta o que mudar', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      final r = c.send('edita o último lançamento')!;
      expect(r.route, 'ask_changes');
      expect(r.text, contains('R\$ 50,00'));
      c.send('45');
      expect(c.created.single.amount, 45);
    });

    test('correção sem nada entendido não diz "Atualizei"', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      final r = c.send('na verdade foi blablablá')!;
      expect(r.text, isNot(contains('Mudei')));
      expect(r.text, contains('O que você quer mudar'));
      expect(c.created.single.amount, 50);
    });

    test('"isso mesmo" confirma sem mudar nada', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      expect(c.send('isso mesmo')!.route, 'confirm');
      expect(c.created.single.amount, 50);
    });

    test('nome de categoria própria logo após o lançamento', () async {
      final c = await fresh();
      c.repo.addBudgetCategory('Pets', 200);
      c.send('gastei 80 no mercado no pix');
      c.send('pets');
      expect(c.created.single.category, c.repo.findCustomCategoryCode('pets'));
    });

    test('a categoria corrigida é lembrada para a próxima vez', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      c.send('esse era lazer');
      expect(c.repo.recallCategoryOverride('Mercado'), 'leisure');
    });
  });

  group('Não dispara em lançamentos normais', () {
    for (final p in [
      'gastei 30 no uber no débito',
      'apaguei a luz e gastei 50',
      'o mercado de ontem estava cheio, gastei 80',
      'o almoço de ontem foi 45',
      'e 30 na padaria',
      'gastei 50 no mercado',
    ]) {
      test('"$p" depois de um lançamento', () async {
        final c = await fresh();
        c.send('gastei 50 no mercado no pix');
        c.assistant.beginTurn();
        // Null, or at most a rewrite into a full new entry ("e 30 na padaria"
        // → "gastei 30 na padaria no pix", FEAT-011) — never an edit/delete.
        final r = c.assistant.handleCommand(p);
        expect(r == null || r.rewrittenInput != null, isTrue, reason: '$r');
        expect(c.created.single.amount, 50);
      });
    }
  });

  group('Resolvedor de referência: editar/excluir qualquer lançamento (FEAT-001, CONV-020)', () {
    test('"exclui o uber" pede confirmação e só apaga com "sim"', () async {
      final c = await fresh([seed('u', 'Uber Viagens', 48, today)]);
      final r = c.send('exclui o uber')!;
      expect(r.route, 'confirm_delete');
      expect(r.text, contains('Uber Viagens'));
      expect(c.has('uber'), isTrue, reason: 'nada é apagado antes do sim');
      final done = c.send('sim')!;
      expect(done.route, 'deleted');
      expect(c.has('uber'), isFalse);
    });

    test('"não" cancela a exclusão', () async {
      final c = await fresh([seed('a', 'Aluguel do Apartamento', 1400, today, category: 'housing')]);
      expect(c.send('apaga o aluguel')!.route, 'confirm_delete');
      expect(c.send('não')!.route, 'delete_canceled');
      expect(c.has('aluguel'), isTrue);
    });

    test('outra frase no lugar do "sim" não apaga e segue normalmente', () async {
      final c = await fresh([seed('u', 'Uber Viagens', 48, today)]);
      c.send('apaga o uber');
      expect(c.send('gastei 30 no uber no débito'), isNull);
      expect(c.assistant.takeNotice(), contains('Não apaguei'));
      expect(c.has('uber'), isTrue);
      expect(c.created.where((t) => t.amount == 30), hasLength(1));
    });

    test('"muda o valor do aluguel pra 1500"', () async {
      final c = await fresh([seed('a', 'Aluguel do Apartamento', 1400, today, category: 'housing')]);
      final r = c.send('muda o valor do aluguel pra 1500')!;
      expect(r.text, contains('o valor de R\$ 1.400,00 para R\$ 1.500,00'));
      expect(c.byTitle('aluguel').amount, 1500);
      expect(c.repo.transactions.length, 1, reason: 'não cria aluguel novo');
    });

    test('"exclui o uber de ontem" escolhe pela data', () async {
      final c = await fresh([seed('u1', 'Uber', 30, yesterday), seed('u2', 'Uber', 25, today)]);
      final r = c.send('exclui o uber de ontem')!;
      expect(r.text, contains('R\$ 30,00'));
      c.send('sim');
      expect(c.repo.transactions.single.amount, 25);
    });

    test('ambíguo: lista as opções e pergunta qual', () async {
      final c = await fresh([seed('m1', 'Mercado Extra', 100, today, category: 'supermarket'), seed('m2', 'Mercado Dia', 60, yesterday, category: 'supermarket')]);
      final r = c.send('apaga o mercado')!;
      expect(r.route, 'choose');
      expect(r.text, allOf(contains('1.'), contains('2.'), contains('Mercado Extra'), contains('Mercado Dia')));
      final confirm = c.send('2')!;
      expect(confirm.route, 'confirm_delete');
      expect(confirm.text, contains('Mercado Dia'));
      c.send('sim');
      expect(c.repo.transactions.single.title, 'Mercado Extra');
    });

    test('escolha pelo valor: "o de 100"', () async {
      final c = await fresh([seed('m1', 'Mercado Extra', 100, today, category: 'supermarket'), seed('m2', 'Mercado Dia', 60, yesterday, category: 'supermarket')]);
      c.send('muda o mercado pra débito');
      final r = c.send('o de 100')!;
      expect(r.route, 'edited');
      expect(c.byTitle('extra').paymentMethod, 'debit_card');
      expect(c.byTitle('dia').paymentMethod, 'pix');
    });

    test('não achou: diz o que procurou e sugere', () async {
      final c = await fresh([seed('u', 'Uber', 30, today.subtract(const Duration(days: 5)))]);
      final r = c.send('apaga o uber de ontem')!;
      expect(r.route, 'not_found');
      expect(r.text, contains('ontem'));
      expect(r.text, contains('Uber'));
      expect(c.send('apaga a netflix')!.text, contains('netflix'));
    });

    test('"apaga o anterior" e "apaga os dois últimos"', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      c.send('gastei 30 no uber no débito');
      expect(c.send('apaga o anterior')!.text, contains('R\$ 50,00'));
      c.send('sim');
      expect(c.created.single.amount, 30);

      final d = await fresh();
      d.send('gastei 50 no mercado no pix');
      d.send('gastei 30 no uber no débito');
      final r = d.send('apaga os dois últimos')!;
      expect(r.text, contains('2 lançamentos'));
      d.send('sim');
      expect(d.created, isEmpty);
    });

    test('"cancela" / "deleta" / "exclui esse lançamento" após salvar pedem confirmação', () async {
      for (final p in ['cancela', 'deleta', 'exclui esse lançamento', 'apaga o último']) {
        final c = await fresh();
        c.send('gastei 50 no mercado no pix');
        expect(c.send(p)!.route, 'confirm_delete', reason: p);
        expect(c.created, hasLength(1));
        c.send('sim');
        expect(c.created, isEmpty, reason: p);
      }
    });

    test('sem prefixo: "o mercado de ontem foi no débito"', () async {
      final c = await fresh([seed('m', 'Mercado', 80, yesterday, category: 'supermarket')]);
      final r = c.send('o mercado de ontem foi no débito')!;
      expect(r.route, 'edited');
      expect(c.byTitle('mercado').paymentMethod, 'debit_card');
    });

    test('"renomeia o último para Padaria"', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      c.send('renomeia o último para Padaria');
      expect(c.created.single.title, 'Padaria');
    });

    test('"apaga o último" sem nada na conversa usa o mais recente', () async {
      final c = await fresh([seed('a', 'Antigo', 10, yesterday), seed('b', 'Novo', 20, today)]);
      final r = c.send('apaga o último')!;
      expect(r.text, contains('Novo'));
    });
  });

  group('Desfazer (FEAT-002, CHAOS-011)', () {
    test('desfaz uma criação', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      final r = c.send('desfaz')!;
      expect(r.route, 'undo');
      expect(r.removedIds, isNotEmpty);
      expect(c.created, isEmpty);
    });

    test('desfaz uma edição', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      c.send('não, foi 45');
      c.send('volta atrás');
      expect(c.created.single.amount, 50);
    });

    test('desfaz uma exclusão ("não era pra apagar, volta")', () async {
      final c = await fresh([seed('u', 'Uber Viagens', 48, today)]);
      c.send('apaga o uber');
      c.send('sim');
      expect(c.has('uber'), isFalse);
      final r = c.send('não era pra apagar, volta')!;
      expect(r.route, 'undo');
      expect(c.byTitle('uber').amount, 48);
    });

    test('pilha: dois desfazer seguidos', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      c.send('muda pra 60');
      c.send('desfaz');
      expect(c.created.single.amount, 50);
      c.send('desfazer');
      expect(c.created, isEmpty);
    });

    test('nada para desfazer', () async {
      final c = await fresh();
      expect(c.send('desfaz')!.route, 'undo_empty');
    });
  });

  group('Contexto de perguntas (FEAT-007, CONV-025)', () {
    Future<Conversation> withData() => fresh([
          seed('m1', 'Mercado', 100, today, category: 'supermarket'),
          seed('u1', 'Uber', 30, today),
          seed('m2', 'Mercado', 40, yesterday, category: 'supermarket'),
          seed('m3', 'Mercado', 999, DateTime(now.year, now.month - 1, 10), category: 'supermarket'),
        ]);

    test('"quanto gastei com mercado esse mês?" ⏎ "e no mês passado?"', () async {
      final c = await withData();
      c.send('quanto gastei com mercado esse mês?');
      final r = c.send('e no mês passado?')!;
      expect(r.route, 'report:spending');
      expect(r.text, contains('R\$ 999,00'));
      expect(r.text, contains('mês passado'));
    });

    test('"quanto gastei com uber?" ⏎ "e com mercado?" (não abre lançamento)', () async {
      final c = await withData();
      c.send('quanto gastei com uber?');
      final r = c.send('e com mercado?')!;
      expect(r.route, 'report:spending');
      expect(r.text, contains('mercado'));
      expect(c.repo.transactions, hasLength(4));
    });

    test('"quanto gastei esse mês?" ⏎ "e ontem?" ⏎ "e em transporte?"', () async {
      final c = await withData();
      c.send('quanto gastei esse mês?');
      final r = c.send('e ontem?')!;
      expect(r.text, contains('ontem'));
      expect(r.text, contains('R\$ 40,00'));
      final t = c.send('e em transporte?')!;
      expect(t.text, contains('não teve gastos com transporte ontem'));
    });

    test('"qual meu saldo?" ⏎ "e quanto recebi?" responde a pergunta nova', () async {
      final c = await withData();
      c.send('qual meu saldo?');
      expect(c.send('e quanto recebi?')!.route, 'report:income');
    });

    test('o contexto expira e "e 30 na padaria" nunca é pergunta', () async {
      final c = await withData();
      c.send('quanto gastei com uber?');
      expect(c.send('e 30 na padaria'), isNull);
      c.send('gastei 10 no café no pix');
      c.send('gastei 12 no café no pix');
      expect(c.send('e ontem?'), isNull);
    });
  });

  group('Conversa e ajuda no fluxo (FEAT-008, CONV-027)', () {
    test('"oi" / "o que você sabe fazer?" não viram lançamento', () async {
      final c = await fresh();
      expect(c.send('oi')!.route, 'smalltalk');
      expect(c.send('o que você sabe fazer?')!.route, 'help');
      expect(c.repo.transactions, isEmpty);
    });

    test('"obrigado" logo após lançar agradece (não é confirmação de correção)', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      expect(c.send('obrigado!')!.text, isNot(contains('fica assim')));
    });

    test('"por que você colocou isso em lazer?" explica e ensina a corrigir', () async {
      final c = await fresh();
      c.send('gastei 60 no restaurante no pix');
      final r = c.send('por que você colocou isso em lazer?')!;
      expect(r.route, 'explain');
      expect(r.text, contains('Lazer'));
      expect(r.text, contains('esse era'));
    });
  });

  group('QA FEAT-010: "gastei o mesmo de ontem no almoço"', () {
    for (final phrase in ['gastei o mesmo de ontem no almoço', 'o mesmo valor de ontem no almoço', 'almoço igual ontem']) {
      test('"$phrase" copia valor e forma de pagamento do almoço de ontem e diz o que copiou', () async {
        final c = await fresh([
          seed('lunch', 'Almoço', 32.5, yesterday, category: 'leisure', pay: 'debit_card'),
          seed('uber', 'Uber', 18, yesterday),
        ]);
        final r = c.send(phrase)!;
        expect(r.route, 'saved');
        expect(r.text, contains('Copiei'));
        expect(r.text, contains('R\$ 32,50'));
        expect(r.text, contains('cartão de débito'));
        final copy = c.created.firstWhere((t) => !t.id.startsWith('seed-'));
        expect([copy.amount, copy.paymentMethod, copy.category], [32.5, 'debit_card', 'leisure']);
        expect(copy.date.day, now.day);
      });
    }

    test('sem lançamento parecido ontem: não inventa, segue perguntando o valor e avisa por quê', () async {
      final c = await fresh([seed('uber', 'Uber', 18, yesterday)]);
      final r = c.assistant..beginTurn();
      final reply = r.handleCommand('gastei o mesmo de ontem no almoço')!;
      expect(reply.rewrittenInput, 'gastei no almoço');
      expect(r.takeNotice(), contains('Não achei'));
      final draft = engine.parse(reply.rewrittenInput!);
      expect(draft.missingSlots, contains('amount'));
      expect(draft.dateOffsetDays, 0);
      expect(c.created, isEmpty);
    });

    test('dois almoços ontem: não escolhe sozinho', () async {
      final c = await fresh([
        seed('l1', 'Almoço', 30, yesterday, category: 'leisure'),
        seed('l2', 'Almoço', 45, yesterday, category: 'leisure'),
      ]);
      final a = c.assistant..beginTurn();
      final reply = a.handleCommand('gastei o mesmo de ontem no almoço')!;
      expect(reply.route, 'rewrite');
      expect(a.takeNotice(), contains('Achei 2'));
    });
  });

  group('QA FEAT-011: "e 30 na padaria" herda a forma de pagamento e conhece a padaria', () {
    for (final follow in ['e 30 na padaria', 'e 12,50 na padaria', 'e 80 no posto']) {
      test('"$follow" registra direto, no Pix, com categoria', () async {
        final c = await fresh();
        c.send('gastei 50 no mercado no pix');
        c.send(follow);
        expect(c.created.length, 2);
        final second = c.created.first; // o repositório guarda o mais novo primeiro
        expect(second.paymentMethod, 'pix');
        expect(second.category, follow.contains('posto') ? 'transport' : 'supermarket');
      });
    }
  });

  group('R2-CONV-001: "na verdade" + lançamento completo é lançamento novo (ou pergunta)', () {
    // Frases novas: outros marcadores, verbos, lugares e registros.
    for (final e in {
      'gastei 60 no açougue no pix': 'na real, também paguei 18 no estacionamento no débito',
      'paguei 45 na farmácia no débito': 'aliás, comprei 30 de pão na padaria no pix',
      'gastei 90 no posto no crédito à vista': 'ops, jantei fora e deu 70 no pix',
      'gastei 120 no mercado no pix': 'na verdade hoje eu recebi 300 do freela no pix',
      'paguei 35 no uber no pix': 'errei, almocei no restaurante e paguei 42 no débito',
    }.entries) {
      test('"${e.value}" depois de "${e.key}" vira lançamento novo e não mexe no anterior', () async {
        final c = await fresh();
        c.send(e.key);
        final before = c.created.single;
        final r = c.send(e.value);
        expect(r, isNull, reason: 'não é comando: ${r?.text}');
        expect(c.created.length, 2);
        final kept = c.created.firstWhere((t) => t.id == before.id);
        expect(kept.amount, before.amount);
        expect(kept.category, before.category);
      });
    }

    test('sem lançamento anterior na conversa, registra (não pergunta "qual lançamento")', () async {
      final c = await fresh();
      final r = c.send('na verdade, ontem eu gastei 25 no sacolão no pix');
      expect(r, isNull);
      expect(c.created.single.amount, 25);
    });

    test('mesmo lugar ou mesma categoria do último: pergunta, e a resposta decide', () async {
      final c = await fresh();
      c.send('gastei 50 no atacadão no pix');
      final ask = c.send('na verdade gastei 38 no atacadão no pix')!;
      expect(ask.route, 'ask_correction_or_new');
      expect(ask.text, contains('Atacadão'));
      expect(c.created.single.amount, 50);
      final fixed = c.send('correção')!;
      expect(fixed.route, 'edited');
      expect(c.created.single.amount, 38);

      final c2 = await fresh();
      c2.send('gastei 50 no atacadão no pix');
      c2.send('na real, comprei 20 no carrefour no pix');
      expect(c2.send('é outro'), isNull);
      expect(c2.created.length, 2);
      expect(c2.created.map((t) => t.amount), containsAll([50.0, 20.0]));
    });

    test('correção de verdade continua funcionando ("na verdade foi 45", "na verdade foi no débito")', () async {
      final c = await fresh();
      c.send('gastei 50 no mercado no pix');
      expect(c.send('na verdade foi 45')!.route, 'edited');
      expect(c.send('na real foi no débito')!.route, 'edited');
      expect(c.created.single.amount, 45);
      expect(c.created.single.paymentMethod, 'debit_card');
    });
  });

  group('R2-CONV-009: frase com lançamento completo não é comando de excluir/editar', () {
    for (final phrase in [
      'excluí o app do banco mas antes paguei 80 da conta de luz no pix',
      'apaguei a luz e depois gastei 30 no mercado no pix',
      'deletei minha conta do ifood, pedi um lanche de 40 no débito',
      'cancelei a academia e paguei 60 de multa no pix',
      'remove essa ideia da cabeça, gastei 90 no posto no crédito à vista',
      'troca de óleo: paguei 150 na oficina no pix',
    ]) {
      test('"$phrase" registra o gasto', () async {
        final c = await fresh();
        final r = c.send(phrase);
        expect(r, isNull, reason: 'virou comando: ${r?.text}');
        expect(c.created, isNotEmpty);
      });
    }

    test('referência a lançamento antigo com oração relativa continua sendo comando', () async {
      final c = await fresh([seed('m', 'Mercado', 50, today, category: 'supermarket')]);
      expect(c.send('apaga o mercado que eu paguei 50 no pix')!.route, 'confirm_delete');
    });
  });
}
