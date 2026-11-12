import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/goal_parser.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AuditReply {
  final String route;
  final String text;
  final FinancialTransactionDraft? draft;
  final bool savedSomething;
  final bool openedPendingDraft;

  const _AuditReply({
    required this.route,
    required this.text,
    this.draft,
    required this.savedSomething,
    required this.openedPendingDraft,
  });

  String get oneLineText {
    final clean = text.replaceAll('\n', ' | ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.length > 130 ? '${clean.substring(0, 130)}…' : clean;
  }
}

/// Espelha exatamente a ordem do funil real em `ChatScreen._sendMessage`,
/// para auditar como comunicações não atreladas a intents transacionais
/// (relatórios, small talk, dúvidas operacionais, desabafos, follow-ups)
/// são respondidas fim-a-fim sem depender de heurísticas isoladas.
class _RealChatSimulator {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  final DateTime Function() clock;
  FinancialTransactionDraft? active;

  _RealChatSimulator(this.engine, this.repo, this.clock)
      : assistant = CesarAssistant(repository: repo, engine: engine, now: clock);

  _AuditReply send(String input) {
    var text = input.trim();
    final txBefore = repo.transactions.length;
    final goalsBefore = repo.goals.length;
    final remBefore = repo.reminders.length;
    engine.setCustomCategories(repo.customCategoryNames);
    assistant.beginTurn();

    // 1. Comandos conversacionais (edição, exclusão, desfaz, categorias, metas, planejamento ativo)
    final cmd = assistant.handleCommand(text, hasPendingDraft: active != null && !active!.isComplete);
    if (cmd != null && cmd.rewrittenInput != null) {
      text = cmd.rewrittenInput!;
    } else if (cmd != null) {
      active = null;
      return _AuditReply(
        route: 'cmd:${cmd.route}',
        text: cmd.text,
        savedSomething: _mutated(txBefore, goalsBefore, remBefore),
        openedPendingDraft: false,
      );
    }

    // 2. Pagamento de dívida
    final debt = DebtPaymentParser.parse(text);
    if (debt != null) {
      final matches = repo.findDebtorsByName(debt.personName);
      if (matches.length == 1) {
        final res = repo.applyDebtPayment(matches.first.id, debt.amountPaid);
        return _AuditReply(
          route: 'debt_payment',
          text: '${debt.personName} pagou ${res.amountPaid}; resta ${res.remainingBalance}',
          savedSomething: true,
          openedPendingDraft: false,
        );
      }
    }

    // 3. Metas
    final goalCreation = GoalParser.parseCreation(text);
    if (goalCreation != null) {
      repo.addGoal(FinancialGoal(
        id: 'goal-${repo.goals.length + 1}',
        title: goalCreation.title,
        targetAmount: goalCreation.targetAmount,
        targetDate: goalCreation.targetDate,
      ));
      return _AuditReply(
        route: 'goal_create',
        text: 'Meta criada: ${goalCreation.title}',
        savedSomething: true,
        openedPendingDraft: false,
      );
    }
    final goalContribution = GoalParser.parseContribution(text);
    if (goalContribution != null) {
      return _AuditReply(
        route: 'goal_contrib',
        text: 'Contribuição para meta: ${goalContribution.goalTitle}',
        savedSomething: _mutated(txBefore, goalsBefore, remBefore),
        openedPendingDraft: false,
      );
    }

    // 4. Affordability ("posso comprar...?")
    final afford = AffordabilityAnalyzer(repository: repo).analyze(text);
    if (afford != null) {
      return _AuditReply(
        route: 'afford:${afford.verdict.name}',
        text: afford.formattedText,
        savedSomething: _mutated(txBefore, goalsBefore, remBefore),
        openedPendingDraft: false,
      );
    }

    // 5. handleQuestion (Preferências, Calculadora, Planner, SmallTalk, Explain, Lookup, Advisor, Hipótese, Q&A/RAG, Unanswered)
    final answer = assistant.handleQuestion(text, hasPendingDraft: active != null && !active!.isComplete);
    if (answer != null) {
      active = null;
      return _AuditReply(
        route: 'qa:${answer.route}',
        text: answer.text,
        savedSomething: _mutated(txBefore, goalsBefore, remBefore),
        openedPendingDraft: false,
      );
    }

    // 6. Multi-lançamento
    final multi = engine.parseMulti(text);
    if (multi.length >= 2) {
      final prompt = engine.multiClarificationPrompt(multi);
      if (prompt == null) {
        for (final d in multi) {
          repo.addTransactionFromDraft(d);
        }
        return _AuditReply(
          route: 'multi_saved',
          text: multi.map((d) => '${d.intent}:${d.description}').join(', '),
          savedSomething: true,
          openedPendingDraft: false,
        );
      }
      return _AuditReply(
        route: 'multi_ask',
        text: prompt,
        savedSomething: false,
        openedPendingDraft: true,
      );
    }

    // 7. Motor NLP / ML fallback (com merge se houver draft ativo, igual ChatScreen)
    final FinancialTransactionDraft draft;
    var merged = false;
    if (active != null && !active!.isComplete && !engine.startsNewTransaction(active!, text)) {
      draft = engine.mergeDrafts(active!, text);
      merged = true;
    } else {
      draft = engine.parse(text);
    }
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      repo.addTransactionFromDraft(draft);
      active = null;
      return _AuditReply(
        route: 'nlp_saved:${draft.intent}',
        text: '${draft.description} (${draft.amount})',
        draft: draft,
        savedSomething: true,
        openedPendingDraft: false,
      );
    }
    if (draft.intent == 'query') {
      active = null;
      return _AuditReply(
        route: 'nlp_query',
        text: engine.replyForQuestion(draft),
        draft: draft,
        savedSomething: false,
        openedPendingDraft: false,
      );
    }
    if (draft.intent == 'unknown' && !merged) {
      active = null;
      return _AuditReply(
        route: 'nlp_unknown',
        text: draft.clarificationPrompt ?? 'Como posso te ajudar com suas finanças hoje?',
        draft: draft,
        savedSomething: false,
        openedPendingDraft: false,
      );
    }

    // Abriu rascunho pendente aguardando complemento de slot (ex.: gasto sem valor/meio)
    active = draft;
    return _AuditReply(
      route: 'nlp_ask:${draft.intent}(missing=${draft.missingSlots.join(",")})',
      text: draft.clarificationPrompt ?? '',
      draft: draft,
      savedSomething: false,
      openedPendingDraft: true,
    );
  }

  bool _mutated(int txBefore, int goalsBefore, int remBefore) =>
      repo.transactions.length != txBefore || repo.goals.length != goalsBefore || repo.reminders.length != remBefore;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;
  final fixedNow = DateTime(2026, 11, 11, 17, 30);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  FinancialRepository seedRepo() {
    final repo = FinancialRepository(seedDemo: false, persistChanges: false);
    // Mês atual (novembro/2026)
    repo.addTransaction(FinancialTransaction(
      id: 'tx-sal-nov',
      title: 'Salário',
      amount: 5500.0,
      type: TransactionType.income,
      category: 'salary',
      paymentMethod: 'pix',
      date: DateTime(2026, 11, 5),
      isRecurrent: true,
      dueBusinessDay: 5,
    ));
    repo.addTransaction(FinancialTransaction(
      id: 'tx-alug-nov',
      title: 'Aluguel',
      amount: 1800.0,
      type: TransactionType.expense,
      category: 'housing',
      paymentMethod: 'bank_slip',
      date: DateTime(2026, 11, 6),
      isRecurrent: true,
      dueDay: 10,
    ));
    repo.addTransaction(FinancialTransaction(
      id: 'tx-merc-nov',
      title: 'Supermercado Extra',
      amount: 620.0,
      type: TransactionType.expense,
      category: 'supermarket',
      paymentMethod: 'pix',
      date: DateTime(2026, 11, 8),
    ));
    repo.addTransaction(FinancialTransaction(
      id: 'tx-ifood-nov',
      title: 'iFood Jantar',
      amount: 145.0,
      type: TransactionType.expense,
      category: 'food',
      paymentMethod: 'credit_card',
      date: DateTime(2026, 11, 10),
    ));
    repo.addTransaction(FinancialTransaction(
      id: 'tx-uber-nov',
      title: 'Uber',
      amount: 42.0,
      type: TransactionType.expense,
      category: 'transport',
      paymentMethod: 'pix',
      date: DateTime(2026, 11, 11),
    ));
    repo.addTransaction(FinancialTransaction(
      id: 'tx-net-nov',
      title: 'Netflix',
      amount: 55.90,
      type: TransactionType.expense,
      category: 'subscriptions',
      paymentMethod: 'credit_card',
      date: DateTime(2026, 11, 3),
      isRecurrent: true,
      dueDay: 3,
    ));
    // Mês passado (outubro/2026)
    repo.addTransaction(FinancialTransaction(
      id: 'tx-sal-oct',
      title: 'Salário',
      amount: 5500.0,
      type: TransactionType.income,
      category: 'salary',
      paymentMethod: 'pix',
      date: DateTime(2026, 10, 5),
      isRecurrent: true,
    ));
    repo.addTransaction(FinancialTransaction(
      id: 'tx-merc-oct',
      title: 'Supermercado Extra',
      amount: 480.0,
      type: TransactionType.expense,
      category: 'supermarket',
      paymentMethod: 'debit_card',
      date: DateTime(2026, 10, 12),
    ));
    repo.addReminder(FinancialReminder(
      id: 'rem-joao',
      title: 'Cobrar João (Empréstimo)',
      personName: 'João',
      amount: 200.0,
      targetDate: DateTime(2026, 11, 20),
      type: ReminderType.loanReceivable,
    ));
    repo.addGoal(FinancialGoal(
      id: 'goal-viagem',
      title: 'Viagem',
      targetAmount: 5000.0,
      savedAmount: 1200.0,
      targetDate: DateTime(2026, 12, 30),
    ));
    return repo;
  }

  _RealChatSimulator newSim() => _RealChatSimulator(engine, seedRepo(), () => fixedNow);

  group('Auditoria de Comunicações Não Atreladas a Intents', () {
    final metrics = <String, Map<String, int>>{};

    void auditGroup(String groupName, List<String> phrases, {bool checkNoSave = true, bool checkNoDraft = true}) {
      // ignore: avoid_print
      print('\n================ $groupName (${phrases.length} casos) ================');
      final counts = <String, int>{};
      for (final p in phrases) {
        final sim = newSim();
        final res = sim.send(p);
        final trace = engine.inspect(p);
        final mlLabel = trace.intentModel.predictedLabel;
        final conf = (trace.intentModel.confidence * 100).toStringAsFixed(0);
        final margin = (trace.intentModel.margin * 100).toStringAsFixed(0);
        final bucket = res.route.startsWith('nlp_unknown')
            ? 'FALLBACK_UNKNOWN'
            : res.route.startsWith('nlp_query') || res.route == 'qa:unanswered'
                ? 'UNANSWERED'
                : res.route.startsWith('nlp_ask')
                    ? 'FALSO_RASCUNHO'
                    : res.route.startsWith('nlp_saved') || res.savedSomething
                        ? 'FALSO_LANCAMENTO'
                        : res.text.contains('Não foi possível identificar o tipo de relatório')
                            ? 'RAG_ERRO'
                            : 'ATENDIDA';
        counts[bucket] = (counts[bucket] ?? 0) + 1;
        // ignore: avoid_print
        print('[$bucket] "$p" -> route=${res.route} | ML=$mlLabel($conf%, Δp=$margin%) | Resp="${res.oneLineText}"');
        if (res.route.startsWith('qa:report:')) {
          expect(
            res.text.contains('Não foi possível identificar o tipo de relatório'),
            isFalse,
            reason: '"$p" não deve cair em erro de RAG quando QA já classificou o relatório',
          );
        }
        if (checkNoSave) {
          expect(res.savedSomething, isFalse, reason: '"$p" não deveria salvar nada, mas caiu em ${res.route}');
        }
        if (checkNoDraft) {
          expect(
            res.openedPendingDraft,
            isFalse,
            reason: '"$p" não deveria abrir rascunho pendente (${res.route}): ${res.text}',
          );
        }
      }
      metrics[groupName] = counts;
    }

    test('1. Visão geral e saúde financeira ("como estão minhas finanças")', () {
      auditGroup('1. Saúde Financeira', [
        'como estão minhas finanças',
        'como estao minhas financas?',
        'como tá minha situação financeira',
        'como tá minhas finanças?',
        'tô no vermelho?',
        'tô no azul?',
        'tô no azul ou no vermelho?',
        'como foi meu mês até agora?',
        'me dá um panorama geral',
        'minha vida financeira tá boa?',
        'estou gastando bem ou mal?',
        'sobra dinheiro no fim do mês?',
      ]);
      // Passo 3 validation: pergunta avaliativa não vira entidade literal "bem ou mal"
      final evalRes = newSim().send('estou gastando bem ou mal?');
      expect(evalRes.text, isNot(contains('gastos com bem')));
    });

    test('2. Onde gastou mais e rankings ("onde eu gastei mais")', () {
      auditGroup('2. Ranking / Onde Gastou Mais', [
        'onde eu gastei mais',
        'onde eu gastei mais?',
        'onde gastei mais esse mês?',
        'em que eu gastei mais?',
        'com o que eu mais gastei?',
        'qual categoria tá pesando mais?',
        'qual foi meu maior gasto',
        'onde foi parar meu salário?',
        'o que mais pesou no mês?',
        'no que eu tô exagerando?',
        'quais são meus gastos fixos?',
        'o que eu pago todo mês?',
      ]);
      // Passo 3 validation: pergunta recorrente vai para assinaturas/fixos, não "gastos com todo"
      final recRes = newSim().send('o que eu pago todo mês?');
      expect(recRes.route, equals('qa:advice:subscriptions'));
      expect(recRes.text, contains('Aluguel'));
    });

    test('3. Consultas livres, fatura, saldo e variações coloquiais', () {
      auditGroup('3. Consultas Livres / Variações', [
        'quanto gastei no mês passado?',
        'gastei quanto com mercado?',
        'quanto entrou de salário?',
        'qual meu saldo?',
        'quanto eu tenho disponível?',
        'gastei mais esse mês ou mês passado?',
        'quanto gastei no cartão de crédito?',
        'qual o valor da minha fatura?',
        'como está minha fatura do cartão?',
        'quanto falta pro salário cair?',
        'tem alguém me devendo?',
        'quais contas vencem essa semana?',
      ]);
      // Passo 5 validation: fatura com transparência de ciclo + contagem para próximo salário
      final f1 = newSim().send('qual o valor da minha fatura?');
      final f2 = newSim().send('como está minha fatura do cartão?');
      expect(f1.route, equals('qa:planner:card_bill_status'));
      expect(f2.route, equals('qa:planner:card_bill_status'));
      expect(f1.text, contains('200,90'));
      final sal = newSim().send('quanto falta pro salário cair?');
      expect(sal.route, equals('qa:planner:payday'));
      expect(sal.text, contains('dias'));
    });

    test('4. Small talk, feedbacks, confirmações soltas e desabafos', () {
      auditGroup('4. SmallTalk / Feedback / Desabafos', [
        'bom dia cesar',
        'e aí, beleza?',
        'valeu pela ajuda!',
        'show',
        'top',
        'perfeito',
        'ok',
        'blz',
        'sim',
        'não',
        'você errou',
        'não gostei dessa resposta',
        'não entendi nada',
        'tô sem dinheiro nenhum',
        'tô muito endividado, me ajuda',
      ]);

      // Passo 2 validation: nenhum desses casos pode responder erro de transação
      for (final p in ['show', 'top', 'ok', 'sim', 'não', 'você errou', 'não gostei dessa resposta', 'não entendi nada', 'tô muito endividado, me ajuda']) {
        final r = newSim().send(p);
        expect(r.text, isNot(contains('Não consegui identificar essa transação')), reason: '"$p" não pode cair em erro transacional');
      }
      // "sim" com rascunho de confirmação pendente deve continuar confirmando o gasto
      final simPending = newSim();
      final askDraft = simPending.send('netflix 55 no credito?');
      expect(askDraft.openedPendingDraft, isTrue);
      final confirmed = simPending.send('sim');
      expect(confirmed.route, equals('nlp_saved:expense'));
      expect(confirmed.savedSomething, isTrue);
    });

    test('5. Dúvidas operacionais do app, privacidade e ajuda', () {
      auditGroup('5. Ajuda / Operação do App', [
        'o que você sabe fazer?',
        'como apago um gasto?',
        'como edito um lançamento?',
        'como mudo a categoria de um gasto?',
        'como exporto meu extrato?',
        'dá pra exportar para excel?',
        'meus dados são privados?',
        'você funciona offline?',
        'como conecto meu banco?',
        'onde vejo meus gráficos?',
      ]);
      // Passo 5 validation: ajuda operacional (Excel/CSV, privacidade/offline, banco, gráficos)
      for (final p in ['dá pra exportar para excel?', 'meus dados são privados?', 'você funciona offline?', 'como conecto meu banco?', 'onde vejo meus gráficos?']) {
        expect(newSim().send(p).route, equals('qa:help'), reason: p);
      }
    });

    test('6. Educação financeira, comparações conceituais e investimentos', () {
      auditGroup('6. Educação Financeira / Conceitual', [
        'o que é selic?',
        'cdb ou poupança?',
        'vale a pena comprar à vista ou parcelado?',
        'regra dos 50 30 20 funciona?',
        'como montar reserva de emergência?',
        'qual a diferença entre débito e crédito?',
      ]);
      // Passo 4 validation: educação financeira + conceitos com números
      expect(newSim().send('cdb ou poupança?').route, equals('qa:planner:knowledge'));
      final r503020 = newSim().send('regra dos 50 30 20 funciona?');
      expect(r503020.route, equals('qa:planner:knowledge'));
      expect(r503020.text, contains('50%'));
      expect(newSim().send('qual a diferença entre débito e crédito?').route, equals('qa:planner:knowledge'));
    });

    test('7. Ponta solta com números em pergunta não-transacional & digitação rápida', () {
      // Nota: algumas frases aqui possuem números sem intent de gasto ("quanto rende 1000 reais...") — auditamos sem checkNoDraft rígido para mapear falsos drafts!
      auditGroup(
        '7. Perguntas c/ Números & Digitação Rápida',
        [
          'qto eu gastei hj?',
          'cm tao minhas financas',
          'oq vc faz?',
          'vc pode me ajudar?',
          'quanto rende 1000 reais no cdi?',
          'melhor investir 500 ou pagar dívida?',
          'posso viajar mês que vem?',
          'dá pra gastar menos em novembro?',
        ],
        checkNoDraft: false,
      );
      // Passo 3 & 4 validations: abreviações, unidade "50 cm", calculadora CDI e desambiguação "investir vs dívida"
      final qtoHj = newSim().send('qto eu gastei hj?');
      expect(qtoHj.text, contains('42,00'));
      expect(qtoHj.text, isNot(contains('qto hj')));
      expect(newSim().send('cm tao minhas financas').route, equals('qa:report:overview'));
      expect(newSim().send('oq vc faz?').route, equals('qa:help'));
      expect(newSim().send('vc pode me ajudar?').route, equals('qa:help'));
      final unitRes = newSim().send('comprei cabo de 50 cm por 30 reais no pix');
      expect(unitRes.savedSomething, isTrue);

      final cdiCalc = newSim().send('quanto rende 1000 reais no cdi?');
      expect(cdiCalc.route, equals('qa:calc'));
      expect(cdiCalc.text, contains('1.008'));

      final investDebt = newSim().send('melhor investir 500 ou pagar dívida?');
      expect(investDebt.route, equals('qa:planner:invest_vs_debt'));
      expect(investDebt.text, isNot(contains('Uma dívida de R\$ 500')));

      // Passo 5 validation: planos sem valor & redução mensal
      final trip = newSim().send('posso viajar mês que vem?');
      expect(trip.route, equals('qa:planner:purchase_ask'));
      expect(trip.text, contains('Viagem'));
      expect(newSim().send('dá pra gastar menos em novembro?').route, equals('qa:planner:cuts'));
    });

    test('8. Follow-ups multi-turno após perguntas não-transacionais', () {
      final scenarios = <List<String>>[
        ['onde eu gastei mais?', 'e no mês passado?'],
        ['como estão minhas finanças', 'e mês passado?'],
        ['quanto gastei com mercado?', 'e no pix?'],
        ['qual foi meu maior gasto?', 'e o segundo maior?'],
        ['como tá minha fatura do cartão?', 'e quanto gastei no crédito?'],
      ];
      // ignore: avoid_print
      print('\n================ 8. Follow-ups Multi-Turno ================');
      for (final turns in scenarios) {
        final sim = newSim();
        final logs = <String>[];
        for (final t in turns) {
          final r = sim.send(t);
          expect(r.savedSomething, isFalse, reason: 'Follow-up "$t" salvou algo indevidamente');
          logs.add('"$t" => [${r.route}] "${r.oneLineText}"');
        }
        // ignore: avoid_print
        print(logs.join('  -->  '));
      }

      // Passo 1 validation: follow-up de overview para mês passado precisa retornar valores de outubro (R$ 480,00)
      final simOverview = newSim();
      final r1 = simOverview.send('como estão minhas finanças');
      final r2 = simOverview.send('e mês passado?');
      expect(r1.route, equals('qa:report:overview'));
      expect(r2.route, equals('qa:report:overview'));
      expect(r2.text, isNot(contains('Não foi possível identificar')));
      expect(r2.text, contains('480,00'));
    });

    tearDownAll(() {
      // ignore: avoid_print
      print('\n================ RESUMO QUANTITATIVO DA AUDITORIA ================');
      int totalAll = 0;
      final globalCounts = <String, int>{};
      metrics.forEach((group, map) {
        final sum = map.values.fold<int>(0, (a, b) => a + b);
        totalAll += sum;
        map.forEach((k, v) => globalCounts[k] = (globalCounts[k] ?? 0) + v);
        // ignore: avoid_print
        print('$group ($sum): $map');
      });
      // ignore: avoid_print
      print('TOTAL AUDITADO: $totalAll casos | Distribuição: $globalCounts');
    });
  });
}

