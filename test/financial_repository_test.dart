import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/persistence_service.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/services/calendar_service.dart';

void main() {
  late FinancialRepository repository;

  setUp(() {
    repository = FinancialRepository();
  });

  group('FinancialRepository - Testes de Gestão e Agregações', () {
    test('Inicialização contém transações e orçamentos padrão', () {
      expect(repository.transactions.isNotEmpty, true);
      expect(repository.budgets.isNotEmpty, true);
      expect(repository.totalBalance, isNotNull);
    });

    test('Adiciona nova transação e recalcula saldo e métricas', () {
      final initialBalance = repository.totalBalance;
      final tx = FinancialTransaction(
        id: 'test-1',
        title: 'Bônus de Desempenho',
        amount: 1000.0,
        type: TransactionType.income,
        category: 'salary',
        paymentMethod: 'pix',
        date: DateTime.now(),
      );

      repository.addTransaction(tx);
      expect(repository.totalBalance, initialBalance + 1000.0);
    });

    test('Adiciona transação a partir de FinancialTransactionDraft (NLP)', () {
      final draft = FinancialTransactionDraft(
        intent: 'expense',
        intentConfidence: 1.0,
        category: 'leisure',
        paymentMethod: 'credit_card',
        amount: 85.0,
        dateOffsetDays: 0,
        description: 'Restaurante Madero',
        rawText: 'gastei 85 no madero no credito',
        latencyMs: 1.2,
        isComplete: true,
        missingSlots: [],
        installments: 2,
        isRecurrent: false,
      );

      final countBefore = repository.transactions.length;
      repository.addTransactionFromDraft(draft);
      expect(repository.transactions.length, countBefore + 1);

      final added = repository.transactions.first;
      expect(added.title, 'Restaurante Madero');
      expect(added.amount, 85.0);
      expect(added.type, TransactionType.expense);
      expect(added.installments, 2);
    });

    test('Exclusão de transação atualiza repositório', () {
      final tx = FinancialTransaction(
        id: 'del-1',
        title: 'Café',
        amount: 15.0,
        type: TransactionType.expense,
        category: 'leisure',
        paymentMethod: 'cash',
        date: DateTime.now(),
      );

      repository.addTransaction(tx);
      expect(repository.transactions.any((t) => t.id == 'del-1'), true);

      repository.deleteTransaction('del-1');
      expect(repository.transactions.any((t) => t.id == 'del-1'), false);
    });

    test('Ajuste de limite de orçamento por categoria', () {
      repository.setBudgetLimit('supermarket', 1500.0);
      final budget = repository.budgets.firstWhere((b) => b.category == 'supermarket');
      expect(budget.monthlyLimit, 1500.0);
    });

    test('Geração de Insight de IA é empático e coerente', () {
      final insight = repository.generateAiInsight();
      expect(insight.isNotEmpty, true);
      expect(insight, isNot(contains('Déficit Orçamentário')));
    });
  });

  group('FinancialRepository - Metas de Economia', () {
    test('Cria meta e calcula progresso e contribuição mensal sugerida', () {
      final target = DateTime.now();
      final goal = FinancialGoal(
        id: 'goal-1',
        title: 'Viagem',
        targetAmount: 1200.0,
        targetDate: DateTime(target.year, target.month + 3, 1),
      );
      repository.addGoal(goal);

      expect(repository.goals.length, 1);
      expect(repository.goals.first.progress, 0.0);
      expect(repository.goals.first.suggestedMonthlyContribution, closeTo(400.0, 0.01));
    });

    test('Contribuir para uma meta acumula o valor guardado e marca como concluída ao bater a meta', () {
      repository.addGoal(FinancialGoal(id: 'goal-2', title: 'Notebook', targetAmount: 300.0));

      final afterFirst = repository.contributeToGoal('goal-2', 100.0);
      expect(afterFirst.savedAmount, 100.0);
      expect(afterFirst.isCompleted, isFalse);

      final afterSecond = repository.contributeToGoal('goal-2', 250.0);
      expect(afterSecond.savedAmount, 350.0);
      expect(afterSecond.isCompleted, isTrue);
      expect(afterSecond.remaining, 0.0);
    });

    test('findGoalsByTitle encontra por substring, acento e caixa, ignorando metas concluídas', () {
      repository.addGoal(FinancialGoal(id: 'goal-3', title: 'Viagem pro Japão', targetAmount: 500.0));
      expect(repository.findGoalsByTitle('viagem').length, 1);
      expect(repository.findGoalsByTitle('JAPAO').length, 1);

      repository.contributeToGoal('goal-3', 500.0);
      expect(repository.findGoalsByTitle('viagem'), isEmpty, reason: 'metas concluídas não devem mais ser encontradas');
    });

    test('deleteGoal remove a meta', () {
      repository.addGoal(FinancialGoal(id: 'goal-4', title: 'Bicicleta', targetAmount: 900.0));
      expect(repository.goals.any((g) => g.id == 'goal-4'), isTrue);
      repository.deleteGoal('goal-4');
      expect(repository.goals.any((g) => g.id == 'goal-4'), isFalse);
    });
  });

  group('FinancialRepository - Memória de Categoria', () {
    test('rememberCategoryOverride/recallCategoryOverride são acento e caixa-insensíveis', () {
      repository.rememberCategoryOverride('Presente de Aniversário', 'leisure');
      expect(repository.recallCategoryOverride('presente de aniversario'), 'leisure');
      expect(repository.recallCategoryOverride('PRESENTE DE ANIVERSÁRIO'), 'leisure');
      expect(repository.recallCategoryOverride('algo nunca visto'), isNull);
    });

    test('applyCategoryMemory retorna o draft com a categoria memorizada, para exibição na UI antes de salvar', () {
      repository.rememberCategoryOverride('Mesa Nova', 'leisure');

      final draft = FinancialTransactionDraft(
        intent: 'expense',
        intentConfidence: 1.0,
        category: 'housing',
        paymentMethod: 'pix',
        amount: 300.0,
        dateOffsetDays: 0,
        description: 'Mesa Nova',
        rawText: 'gastei 300 numa mesa nova no pix',
        latencyMs: 1.0,
        isComplete: true,
        missingSlots: [],
      );

      final withMemory = repository.applyCategoryMemory(draft);
      expect(withMemory.category, 'leisure');

      // A second, unrelated description without a remembered override stays untouched.
      final unrelated = draft.copyWith(description: 'Item Nunca Visto');
      expect(repository.applyCategoryMemory(unrelated).category, 'housing');
    });

    test('addTransactionFromDraft aplica automaticamente uma categoria memorizada', () {
      repository.rememberCategoryOverride('Cadeira Gamer', 'leisure');

      final draft = FinancialTransactionDraft(
        intent: 'expense',
        intentConfidence: 1.0,
        category: 'housing', // o que o engine normalmente sugeriria para "cadeira"
        paymentMethod: 'pix',
        amount: 500.0,
        dateOffsetDays: 0,
        description: 'Cadeira Gamer',
        rawText: 'gastei 500 na cadeira gamer no pix',
        latencyMs: 1.0,
        isComplete: true,
        missingSlots: [],
      );

      repository.addTransactionFromDraft(draft);
      final added = repository.transactions.first;
      expect(added.title, 'Cadeira Gamer');
      expect(added.category, 'leisure', reason: 'a memória de categoria deve sobrepor a sugestão padrão do engine');
    });
  });

  group('FinancialRepository - Alertas Proativos', () {
    test('Gera alerta crítico quando uma categoria estoura o orçamento', () {
      repository.setBudgetLimit('leisure', 100.0);
      repository.addTransaction(FinancialTransaction(
        id: 'over-1',
        title: 'Show',
        amount: 150.0,
        type: TransactionType.expense,
        category: 'leisure',
        paymentMethod: 'pix',
        date: DateTime.now(),
      ));

      final alerts = repository.getProactiveAlerts();
      expect(alerts.any((a) => a.id == 'budget-over-leisure' && a.severity == ProactiveAlertSeverity.critical), isTrue);
    });

    test('Sem nenhum problema pendente, não há alertas', () {
      final freshRepo = FinancialRepository();
      // Zera qualquer transação padrão que aproxime algum orçamento do limite.
      for (final tx in freshRepo.transactions.toList()) {
        freshRepo.deleteTransaction(tx.id);
      }
      expect(freshRepo.getProactiveAlerts(), isEmpty);
    });
  });

  group('FinancialRepository - Comparativo Mês a Mês', () {
    test('monthOverMonthExpenseChange retorna null sem dados do mês anterior', () {
      final freshRepo = FinancialRepository();
      for (final tx in freshRepo.transactions.toList()) {
        freshRepo.deleteTransaction(tx.id);
      }
      expect(freshRepo.monthOverMonthExpenseChange, isNull);
    });

    test('monthOverMonthExpenseChange calcula variação percentual corretamente', () {
      final freshRepo = FinancialRepository();
      for (final tx in freshRepo.transactions.toList()) {
        freshRepo.deleteTransaction(tx.id);
      }
      final now = DateTime.now();
      final prevMonth = DateTime(now.year, now.month - 1, 10);

      freshRepo.addTransaction(FinancialTransaction(
        id: 'prev-1',
        title: 'Gasto mês passado',
        amount: 100.0,
        type: TransactionType.expense,
        category: 'leisure',
        paymentMethod: 'pix',
        date: prevMonth,
      ));
      freshRepo.addTransaction(FinancialTransaction(
        id: 'curr-1',
        title: 'Gasto deste mês',
        amount: 150.0,
        type: TransactionType.expense,
        category: 'leisure',
        paymentMethod: 'pix',
        date: now,
      ));

      expect(freshRepo.monthOverMonthExpenseChange, closeTo(50.0, 0.01));
    });
  });

  group('FinancialRepository - Categorias Personalizadas', () {
    test('addBudgetCategory cria uma categoria custom com código slugificado', () {
      final created = repository.addBudgetCategory('Pets & Vet', 250.0);
      expect(created.category, 'pets_vet');
      expect(created.isCustom, isTrue);
      expect(repository.budgets.any((b) => b.category == 'pets_vet'), isTrue);
    });

    test('addBudgetCategory com nome que já existe apenas atualiza o limite (sem duplicar)', () {
      repository.addBudgetCategory('Pets', 200.0);
      repository.addBudgetCategory('Pets', 300.0);
      final matches = repository.budgets.where((b) => b.category == 'pets').toList();
      expect(matches.length, 1);
      expect(matches.first.monthlyLimit, 300.0);
    });

    test('removeBudgetCategory remove apenas categorias custom, não as built-in', () {
      repository.addBudgetCategory('Pets', 200.0);
      repository.removeBudgetCategory('pets');
      expect(repository.budgets.any((b) => b.category == 'pets'), isFalse);

      // Built-in category is protected even if removeBudgetCategory is called on it.
      repository.removeBudgetCategory('supermarket');
      expect(repository.budgets.any((b) => b.category == 'supermarket'), isTrue);
    });

    test('findCustomCategoryCode encontra por nome ou código, ignora acento e caixa', () {
      repository.addBudgetCategory('Presentes', 150.0);
      expect(repository.findCustomCategoryCode('presentes'), 'presentes');
      expect(repository.findCustomCategoryCode('PRESENTES'), 'presentes');
      expect(repository.findCustomCategoryCode('presentes'), isNotNull);
      expect(repository.findCustomCategoryCode('categoria inexistente'), isNull);
      // Built-in categories are not returned by this lookup (it's custom-only).
      expect(repository.findCustomCategoryCode('supermarket'), isNull);
    });

    test('uma transação numa categoria custom conta para o gasto daquela categoria', () {
      repository.addBudgetCategory('Pets', 200.0);
      repository.addTransaction(FinancialTransaction(
        id: 'pet-1',
        title: 'Ração',
        amount: 80.0,
        type: TransactionType.expense,
        category: 'pets',
        paymentMethod: 'pix',
        date: DateTime.now(),
      ));
      final petsBudget = repository.budgets.firstWhere((b) => b.category == 'pets');
      expect(petsBudget.currentSpent, 80.0);
    });

    test('renameBudgetCategory troca só o nome — código, gasto e transações continuam ligados', () {
      repository.addBudgetCategory('Pets', 200.0);
      repository.addTransaction(FinancialTransaction(
        id: 'pet-1',
        title: 'Ração',
        amount: 80.0,
        type: TransactionType.expense,
        category: 'pets',
        paymentMethod: 'pix',
        date: DateTime.now(),
      ));

      expect(repository.renameBudgetCategory('pets', '  Animais de Estimação '), isTrue);

      final renamed = repository.budgets.firstWhere((b) => b.category == 'pets');
      expect(renamed.name, 'Animais de Estimação');
      expect(renamed.currentSpent, 80.0);
      expect(renamed.monthlyLimit, 200.0);
      expect(repository.findCustomCategoryCode('animais de estimacao'), 'pets');
    });

    test('renameBudgetCategory recusa nome vazio, nome duplicado e categoria padrão', () {
      repository.addBudgetCategory('Pets', 200.0);
      repository.addBudgetCategory('Presentes', 150.0);

      expect(repository.renameBudgetCategory('pets', '   '), isFalse);
      expect(repository.renameBudgetCategory('pets', 'presentes'), isFalse);
      expect(repository.renameBudgetCategory('pets', 'Supermercado'), isFalse);
      expect(repository.renameBudgetCategory('supermarket', 'Mercado'), isFalse);

      expect(repository.budgets.firstWhere((b) => b.category == 'pets').name, 'Pets');
      expect(repository.budgets.firstWhere((b) => b.category == 'supermarket').name, 'Supermercado');
    });
  });

  group('FinancialRepository - Correção pelo chat', () {
    FinancialTransactionDraft draft({String category = 'expense_other', String payment = 'pix', int? installments}) =>
        FinancialTransactionDraft(
          intent: 'expense',
          intentConfidence: 1,
          category: category,
          paymentMethod: payment,
          amount: 500.0,
          dateOffsetDays: 0,
          description: 'Blusa',
          rawText: 'comprei uma blusa de 500',
          latencyMs: 1,
          isComplete: true,
          missingSlots: const [],
          installments: installments,
        );

    test('addTransactionFromDraft devolve o lançamento salvo', () {
      final saved = repository.addTransactionFromDraft(draft());
      expect(saved, hasLength(1));
      expect(repository.transactions.any((t) => t.id == saved.single.id), isTrue);
    });

    test('rascunho de diárias vira um lançamento por dia, em dias consecutivos', () {
      final before = repository.transactions.length;
      final daily = FinancialTransactionDraft(
        intent: 'expense',
        intentConfidence: 1,
        category: 'expense_other',
        paymentMethod: 'pix',
        amount: 50.0,
        dateOffsetDays: 0,
        description: 'Diária de pedreiro',
        rawText: 'contratei um pedreiro pagando 50 reais o dia durante 10 dias',
        latencyMs: 1,
        isComplete: true,
        missingSlots: const [],
        repeatDays: 10,
      );

      final saved = repository.addTransactionFromDraft(daily);

      expect(saved, hasLength(10));
      expect(repository.transactions.length, before + 10);
      expect(saved.every((t) => t.amount == 50.0), isTrue);
      expect(saved.first.title, 'Diária de pedreiro (1/10)');
      expect(saved.last.title, 'Diária de pedreiro (10/10)');
      for (var i = 1; i < saved.length; i++) {
        expect(saved[i].date.difference(saved[i - 1].date).inDays, 1);
      }
      expect(saved.map((t) => t.id).toSet(), hasLength(10));
    });

    test('conta com vencimento no 5º dia útil usa a data real de cada mês', () {
      final now = DateTime.now();
      repository.addTransaction(FinancialTransaction(
        id: 'payroll',
        title: 'Salário de funcionário',
        amount: 1650.0,
        type: TransactionType.expense,
        category: 'expense_other',
        paymentMethod: 'pix',
        date: now,
        isRecurrent: true,
        dueDay: 5,
        dueBusinessDay: 5,
      ));

      final bills = repository
          .getUpcomingBills(start: DateTime(now.year, now.month, 1), end: DateTime(now.year, now.month + 2, 0))
          .where((b) => b['id'] == 'payroll')
          .toList();

      expect(bills, isNotEmpty);
      for (final b in bills) {
        final due = b['dueDate'] as DateTime;
        expect(due.day, RealtimeCalendarService.nthBusinessDay(due, 5).day);
      }
    });

    test('applyDraftCorrection altera categoria e pagamento do lançamento salvo', () {
      repository.addBudgetCategory('Roupas', 300.0);
      final tx = repository.addTransactionFromDraft(draft()).single;

      repository.applyDraftCorrection(tx.id, draft(category: 'roupas', payment: 'credit_card', installments: 3));

      final saved = repository.transactions.firstWhere((t) => t.id == tx.id);
      expect(saved.category, 'roupas');
      expect(saved.paymentMethod, 'credit_card');
      expect(saved.installments, 3);
      expect(repository.budgets.firstWhere((b) => b.category == 'roupas').currentSpent, 500.0);
    });

    test('findCustomCategoryCode tolera singular/plural e acento', () {
      repository.addBudgetCategory('Funcionários', 3000.0);
      expect(repository.findCustomCategoryCode('funcionario'), 'funcionarios');
      expect(repository.findCustomCategoryCode('Funcionários'), 'funcionarios');
    });
  });

  group('FinancialRepository - Edição de Lançamentos', () {
    test('updateTransaction substitui o lançamento e recalcula saldo e orçamento', () {
      final tx = FinancialTransaction(
        id: 'edit-1',
        title: 'Mercado',
        amount: 100.0,
        type: TransactionType.expense,
        category: 'supermarket',
        paymentMethod: 'pix',
        date: DateTime.now(),
      );
      repository.addTransaction(tx);
      final balanceBefore = repository.totalBalance;
      final spentBefore = repository.budgets.firstWhere((b) => b.category == 'supermarket').currentSpent;

      repository.updateTransaction(tx.copyWith(title: 'Feira', amount: 60.0, category: 'leisure'));

      final saved = repository.transactions.where((t) => t.id == 'edit-1').toList();
      expect(saved, hasLength(1));
      expect(saved.single.title, 'Feira');
      expect(repository.totalBalance, closeTo(balanceBefore + 40.0, 0.001));
      expect(repository.budgets.firstWhere((b) => b.category == 'supermarket').currentSpent, closeTo(spentBefore - 100.0, 0.001));
    });

    test('updateTransaction de despesa para receita inverte o efeito no saldo', () {
      final tx = FinancialTransaction(
        id: 'edit-2',
        title: 'Entrada',
        amount: 500.0,
        type: TransactionType.expense,
        category: 'expense_other',
        paymentMethod: 'pix',
        date: DateTime.now(),
      );
      repository.addTransaction(tx);
      final balanceBefore = repository.totalBalance;

      repository.updateTransaction(tx.copyWith(type: TransactionType.income, category: 'income_other'));

      expect(repository.totalBalance, closeTo(balanceBefore + 1000.0, 0.001));
    });
  });

  group('FinancialRepository - Persistência', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('initialize() na primeira execução persiste o seed e marca como semeado', () async {
      final repo = FinancialRepository();
      await repo.initialize();

      final persistence = PersistenceService();
      expect(await persistence.hasPersistedData(), isTrue);
      final savedTxs = await persistence.loadTransactions();
      expect(savedTxs.length, repo.transactions.length);
    });

    test('uma nova instância carrega o estado persistido em vez do seed padrão', () async {
      final repoA = FinancialRepository();
      await repoA.initialize();
      repoA.addTransaction(FinancialTransaction(
        id: 'persisted-1',
        title: 'Transação Persistida',
        amount: 42.0,
        type: TransactionType.expense,
        category: 'leisure',
        paymentMethod: 'pix',
        date: DateTime.now(),
      ));

      final repoB = FinancialRepository();
      await repoB.initialize();

      expect(repoB.transactions.any((t) => t.id == 'persisted-1'), isTrue);
      expect(repoB.transactions.length, repoA.transactions.length);
    });

    test('clearAllData() apaga tudo e reseta os orçamentos padrão', () async {
      final repo = FinancialRepository();
      await repo.initialize();
      repo.addGoal(FinancialGoal(id: 'g-clear', title: 'Teste', targetAmount: 100.0));

      await repo.clearAllData();

      expect(repo.transactions, isEmpty);
      expect(repo.reminders, isEmpty);
      expect(repo.goals, isEmpty);
      expect(repo.budgets, isNotEmpty); // defaults restored

      // R2-CHAOS-010: an emptied app is real (empty) data, not a first run —
      // otherwise the next start brings the demo seed back.
      final persistence = PersistenceService();
      expect(await persistence.hasPersistedData(), isTrue);
    });

    test('Regression: dados criados após clearAllData() sobrevivem a um novo restart, em vez de serem substituídos pelo seed de demonstração', () async {
      final repoA = FinancialRepository();
      await repoA.initialize();

      await repoA.clearAllData();
      // Real work happens in the same session, right after clearing test data.
      repoA.addTransaction(FinancialTransaction(
        id: 'real-1',
        title: 'Compra real pós-limpeza',
        amount: 77.0,
        type: TransactionType.expense,
        category: 'leisure',
        paymentMethod: 'pix',
        date: DateTime.now(),
      ));
      repoA.addBudgetCategory('Pets', 150.0);
      await repoA.flushPendingWrites();

      // Simulates the app being restarted: a brand-new repository instance
      // loading from the same persisted storage.
      final repoB = FinancialRepository();
      await repoB.initialize();

      expect(repoB.transactions.any((t) => t.id == 'real-1'), isTrue,
          reason: 'real post-clear work must not be silently discarded on restart');
      expect(repoB.budgets.any((b) => b.category == 'pets'), isTrue);
      // Crucially, the demo seed transactions must NOT have reappeared.
      expect(repoB.transactions.any((t) => t.title == 'Salário Mensal'), isFalse);
    });

    FinancialTransaction burstTx(String id) => FinancialTransaction(
          id: id,
          title: 'Rajada $id',
          amount: 10.0,
          type: TransactionType.expense,
          category: 'leisure',
          paymentMethod: 'pix',
          date: DateTime.now(),
        );

    test('rajada de mudanças é salva por completo (gravações agrupadas)', () async {
      final repoA = FinancialRepository();
      await repoA.initialize();
      for (var i = 0; i < 300; i++) {
        repoA.addTransaction(burstTx('burst-$i'));
      }
      await repoA.flushPendingWrites();

      final repoB = FinancialRepository();
      await repoB.initialize();
      expect(repoB.transactions.length, repoA.transactions.length);
      expect(repoB.transactions.any((t) => t.id == 'burst-299'), isTrue);
    });

    test('mudança → limpar histórico → mudança, sem esperar a gravação: a última mudança sobrevive', () async {
      final repoA = FinancialRepository();
      await repoA.initialize();
      repoA.addTransaction(burstTx('before-clear'));
      final clearing = repoA.clearAllData();
      repoA.addTransaction(burstTx('after-clear'));
      await clearing;
      await repoA.flushPendingWrites();

      final repoB = FinancialRepository();
      await repoB.initialize();
      expect(repoB.transactions.any((t) => t.id == 'after-clear'), isTrue);
      expect(repoB.transactions.any((t) => t.id == 'before-clear'), isFalse);
    });
  });

  group('QA CONV-006, CHAOS-001: ids únicos no mesmo milissegundo', () {
    FinancialTransactionDraft draft(String desc, String category, double amount) => FinancialTransactionDraft(
          intent: 'expense',
          intentConfidence: 1.0,
          category: category,
          paymentMethod: 'pix',
          amount: amount,
          dateOffsetDays: 0,
          description: desc,
          rawText: desc,
          latencyMs: 1.0,
          isComplete: true,
          missingSlots: const [],
        );

    test('multi-lançamento salvo de uma vez: apagar um não apaga o outro', () {
      final repo = FinancialRepository();
      final uber = repo.addTransactionFromDraft(draft('Uber', 'transport', 20)).single;
      final mercado = repo.addTransactionFromDraft(draft('Mercado', 'supermarket', 30)).single;
      final farmacia = repo.addTransactionFromDraft(draft('Farmácia', 'health', 40)).single;
      expect({uber.id, mercado.id, farmacia.id}, hasLength(3));

      repo.deleteTransaction(mercado.id);
      expect(repo.transactions.any((t) => t.id == uber.id), isTrue);
      expect(repo.transactions.any((t) => t.id == farmacia.id), isTrue);
      expect(repo.transactions.any((t) => t.id == mercado.id), isFalse);
    });

    test('corrigir um não corrige o outro', () {
      final repo = FinancialRepository();
      final a = repo.addTransactionFromDraft(draft('Uber', 'transport', 20)).single;
      final b = repo.addTransactionFromDraft(draft('Mercado', 'supermarket', 30)).single;
      repo.applyDraftCorrection(b.id, draft('Mercado', 'supermarket', 45));
      expect(repo.transactions.firstWhere((t) => t.id == a.id).amount, 20);
      expect(repo.transactions.firstWhere((t) => t.id == b.id).amount, 45);
    });

    test('diárias e pagamento de dívida também ganham ids únicos', () {
      final repo = FinancialRepository();
      final days = repo.addTransactionFromDraft(draft('Diária', 'expense_other', 50).copyWith(repeatDays: 3));
      final single = repo.addTransactionFromDraft(draft('Uber', 'transport', 20));
      final debtor = repo.getActiveDebtors().first;
      final p1 = repo.applyDebtPayment(debtor.id, 10).transaction;
      final p2 = repo.applyDebtPayment(debtor.id, 10).transaction;
      final ids = [...days.map((t) => t.id), ...single.map((t) => t.id), p1.id, p2.id];
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('QA CHAOS-009: categoria recriada mostra o gasto', () {
    test('remover e recriar "Pets" recalcula o gasto do mês', () {
      final repo = FinancialRepository();
      repo.addBudgetCategory('Pets', 300);
      repo.addTransaction(FinancialTransaction(
        id: 'pet-1',
        title: 'Ração',
        amount: 120,
        type: TransactionType.expense,
        category: 'pets',
        paymentMethod: 'pix',
        date: DateTime.now(),
      ));
      repo.removeBudgetCategory('pets');
      final recreated = repo.addBudgetCategory('Pets', 300);
      expect(recreated.currentSpent, 120);
      expect(repo.budgets.firstWhere((b) => b.category == 'pets').currentSpent, 120);
    });
  });

  group('QA CHAOS-014/015: criar categoria não sobrescreve outra', () {
    test('nome que vira código de categoria nativa não renomeia a nativa', () {
      final repo = FinancialRepository();
      for (final name in ['Supermarket', 'Health', 'Transport']) {
        final created = repo.addBudgetCategory(name, 357);
        expect(created.isCustom, isTrue, reason: name);
      }
      expect(repo.budgets.firstWhere((b) => b.category == 'supermarket').name, 'Supermercado');
      expect(repo.budgets.firstWhere((b) => b.category == 'supermarket').monthlyLimit, 1200);
      expect(repo.budgets.firstWhere((b) => b.category == 'health').name, 'Saúde & Farmácia');
    });

    test('nomes sem letras ganham códigos distintos; nome repetido não duplica', () {
      final repo = FinancialRepository();
      final a = repo.addBudgetCategory('!!!', 100);
      final b = repo.addBudgetCategory('???', 200);
      expect(a.category, isNot(b.category));
      expect(repo.budgets.where((x) => x.name == '!!!'), hasLength(1));

      final before = repo.budgets.length;
      final same = repo.addBudgetCategory('Supermercado', 999);
      expect(same.category, 'supermarket');
      expect(same.monthlyLimit, 1200, reason: 'categoria nativa não muda por "criar categoria"');
      repo.addBudgetCategory('Pets', 100);
      repo.addBudgetCategory('PETS ', 150);
      expect(repo.budgets.length, before + 1);
      expect(repo.budgets.firstWhere((x) => x.category == 'pets').monthlyLimit, 150);
    });

    test('nome vazio ou limite inválido é recusado', () {
      final repo = FinancialRepository();
      expect(() => repo.addBudgetCategory('   ', 100), throwsArgumentError);
      expect(() => repo.addBudgetCategory('Viagem', double.nan), throwsArgumentError);
    });
  });

  group('Faixa de valor monetário (R\$ 0,01 a R\$ 100 bilhões)', () {
    FinancialTransaction tx(String id, double amount) => FinancialTransaction(
          id: id,
          title: 'Teste',
          amount: amount,
          type: TransactionType.expense,
          category: 'supermarket',
          paymentMethod: 'pix',
          date: DateTime.now(),
        );

    test('sub-centavo e valores absurdos não são gravados', () {
      final before = repository.transactions.length;
      repository.addTransaction(tx('sub', 0.001));
      repository.addTransaction(tx('huge', 1e15));
      expect(repository.transactions.length, before);
    });

    test('limites da faixa são aceitos', () {
      final before = repository.transactions.length;
      repository.addTransaction(tx('min', 0.01));
      repository.addTransaction(tx('max', 1e11));
      expect(repository.transactions.length, before + 2);
    });

    test('recalcular orçamentos com muitos lançamentos e categorias continua rápido', () {
      for (var i = 0; i < 2000; i++) {
        repository.addTransaction(tx('perf$i', 10));
      }
      final sw = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        repository.addBudgetCategory('Categoria $i', 100);
      }
      // Antes, cada recálculo percorria todo o histórico uma vez por categoria.
      expect(sw.elapsedMilliseconds, lessThan(3000));
      expect(repository.budgets.firstWhere((b) => b.category == 'supermarket').currentSpent, greaterThanOrEqualTo(20000));
    });
  });

  group('QA CHAOS-016: valores NaN/∞/negativos são recusados', () {
    FinancialTransactionDraft draftOf(double amount) => FinancialTransactionDraft(
          intent: 'expense',
          intentConfidence: 1.0,
          category: 'supermarket',
          paymentMethod: 'pix',
          amount: amount,
          dateOffsetDays: 0,
          description: 'Mercado',
          rawText: 'x',
          latencyMs: 1.0,
          isComplete: true,
          missingSlots: const [],
        );

    test('lançamento, correção e edição não aceitam NaN/∞', () {
      final repo = FinancialRepository();
      final balance = repo.totalBalance;
      expect(repo.addTransactionFromDraft(draftOf(double.nan)), isEmpty);
      expect(repo.addTransactionFromDraft(draftOf(double.infinity)), isEmpty);
      final tx = repo.addTransactionFromDraft(draftOf(10)).single;
      repo.applyDraftCorrection(tx.id, draftOf(double.infinity));
      expect(repo.transactions.firstWhere((t) => t.id == tx.id).amount, 10);
      repo.addTransaction(FinancialTransaction(
        id: 'nan-1', title: 'x', amount: double.nan, type: TransactionType.expense,
        category: 'supermarket', paymentMethod: 'pix', date: DateTime.now(),
      ));
      expect(repo.transactions.any((t) => t.id == 'nan-1'), isFalse);
      expect(repo.totalBalance.isFinite, isTrue);
      expect(repo.totalBalance, closeTo(balance - 10, 0.001));
    });

    test('pagamento de dívida inválido não mexe na dívida', () {
      final repo = FinancialRepository();
      final debtor = repo.getActiveDebtors().first;
      final owed = debtor.amount;
      for (final v in [0.0, -50.0, double.nan, double.infinity]) {
        expect(() => repo.applyDebtPayment(debtor.id, v), throwsArgumentError, reason: '$v');
      }
      expect(repo.getActiveDebtors().first.amount, owed);
    });

    test('metas não aceitam NaN nem aporte negativo', () {
      final repo = FinancialRepository();
      repo.addGoal(FinancialGoal(id: 'g-nan', title: 'X', targetAmount: double.nan));
      expect(repo.goals.any((g) => g.id == 'g-nan'), isFalse);
      repo.addGoal(FinancialGoal(id: 'g-1', title: 'Viagem', targetAmount: 1000));
      expect(repo.contributeToGoal('g-1', -300).savedAmount, 0);
      expect(repo.contributeToGoal('g-1', double.nan).savedAmount, 0);
      expect(repo.contributeToGoal('g-1', 100).savedAmount, 100);
    });
  });

  group('QA rodada 2: dívida, contas e categorias (CONV-036, CHAOS-022 a 025)', () {
    test('CONV-036: pagamento maior que a dívida quita e informa o excedente', () {
      for (final extra in [150.0, 0.5, 1000.0]) {
        final repo = FinancialRepository();
        final joao = repo.findDebtorsByName('João').single;
        final owed = joao.amount!;
        final r = repo.applyDebtPayment(joao.id, owed + extra);
        expect(r.isFullyPaid, isTrue);
        expect(r.previousBalance, owed);
        expect(r.excess, closeTo(extra, 0.001));
        expect(repo.findDebtorsByName('João'), isEmpty);
      }
      final repo = FinancialRepository();
      final joao = repo.findDebtorsByName('João').single;
      expect(repo.applyDebtPayment(joao.id, 50).excess, 0.0);
    });

    test('CHAOS-024: dívida já quitada (ou marcada como concluída) não recebe pagamento', () {
      final repo = FinancialRepository();
      final joao = repo.findDebtorsByName('João').single;
      repo.toggleReminderCompleted(joao.id);
      final before = repo.transactions.length;
      expect(() => repo.applyDebtPayment(joao.id, 2992.68), throwsStateError);
      expect(repo.transactions.length, before);
    });

    test('CHAOS-022: conta com margem sem valor não cria lançamento de R\$ 0', () {
      final repo = FinancialRepository();
      final before = repo.transactions.length;
      repo.addBillWithMargin(title: 'Luz', billingDay: 1, dueDay: 5);
      repo.addBillWithMargin(title: 'Água', billingDay: 1, dueDay: 5, amount: 0);
      repo.addBillWithMargin(title: 'Gás', billingDay: 1, dueDay: 5, amount: double.nan);
      expect(repo.transactions.length, before);
      repo.addBillWithMargin(title: 'Internet', billingDay: 1, dueDay: 5, amount: 99.9);
      expect(repo.transactions.length, before + 1);
    });

    test('CHAOS-023: nomes de categoria com espaços não duplicam', () {
      final repo = FinancialRepository();
      final pets = repo.addBudgetCategory('PETS ', 100);
      expect(pets.name, 'PETS');
      expect(() => repo.addBudgetCategory('  ', 100), throwsArgumentError);
      final other = repo.addBudgetCategory('Bichos', 50);
      expect(repo.renameBudgetCategory(other.category, 'PETS '), isFalse);
      expect(repo.renameBudgetCategory(other.category, ' pets'), isFalse);
      expect(repo.budgets.where((b) => b.name.trim().toLowerCase() == 'pets').length, 1);
    });

    test('CHAOS-025: correção sem tipo (intent unknown/query) mantém o tipo do lançamento', () {
      final repo = FinancialRepository();
      final income = repo.transactions.firstWhere((t) => t.type == TransactionType.income);
      for (final intent in ['unknown', 'query']) {
        repo.applyDraftCorrection(
          income.id,
          FinancialTransactionDraft(
            intent: intent, intentConfidence: 1, category: 'unknown', paymentMethod: 'unknown', amount: null,
            dateOffsetDays: 0, description: '', rawText: '', latencyMs: 0, isComplete: true, missingSlots: const [],
          ),
        );
        expect(repo.transactions.firstWhere((t) => t.id == income.id).type, TransactionType.income, reason: intent);
      }
    });
  });

  group('R2-CHAOS-010/011/012/021: persistência na borda do initialize e do "Limpar Histórico"', () {
    FinancialTransaction tx(String id, double amount) => FinancialTransaction(
        id: id, title: 'T $id', amount: amount, type: TransactionType.expense, category: 'leisure', paymentMethod: 'pix', date: DateTime.now());

    test('"Limpar Histórico" e recarregar sem lançar nada: o app continua vazio (sem o seed)', () async {
      SharedPreferences.setMockInitialValues({});
      final a = FinancialRepository();
      await a.initialize();
      await a.clearAllData();
      for (var restart = 0; restart < 2; restart++) {
        final b = FinancialRepository();
        await b.initialize();
        expect(b.transactions, isEmpty, reason: 'reinício $restart');
        expect(b.budgets, isNotEmpty);
      }
    });

    test('dados da nuvem que chegam durante o initialize() não são descartados (memória e disco)', () async {
      SharedPreferences.setMockInitialValues({});
      final old = FinancialRepository();
      await old.initialize();
      old.addTransaction(tx('local-antigo', 10));
      await old.flushPendingWrites();

      // main.dart starts _loadRepository and _initFirebase in parallel: the
      // snapshot can land at any point of the load.
      for (var k = 0; k <= 6; k++) {
        final repo = FinancialRepository();
        final init = repo.initialize();
        for (var j = 0; j < k; j++) {
          await Future<void>.microtask(() {});
        }
        repo.replaceAllFromCloud(transactions: [tx('nuvem-$k', 99)], reminders: const [], budgets: const [], goals: const [], categoryOverrides: const {});
        await init;
        await repo.flushPendingWrites();
        expect(repo.transactions.map((t) => t.id), ['nuvem-$k'], reason: 'memória, $k microtarefas');

        final reopened = FinancialRepository();
        await reopened.initialize();
        expect(reopened.transactions.map((t) => t.id), ['nuvem-$k'], reason: 'disco, $k microtarefas');
      }
    });

    test('lançamento feito antes do initialize() terminar não apaga os dados salvos', () async {
      SharedPreferences.setMockInitialValues({});
      final old = FinancialRepository();
      await old.initialize();
      await old.clearAllData();
      old.addTransaction(tx('salvo-1', 20));
      await old.flushPendingWrites();

      final repo = FinancialRepository();
      final init = repo.initialize();
      repo.addTransaction(tx('novo-x', 30));
      await init;
      await repo.flushPendingWrites();
      expect(repo.transactions.map((t) => t.id).toSet(), {'salvo-1', 'novo-x'});

      final reopened = FinancialRepository();
      await reopened.initialize();
      expect(reopened.transactions.map((t) => t.id).toSet(), {'salvo-1', 'novo-x'});
    });

    test('dataGeneration muda quando os dados são trocados por inteiro (limpeza ou nuvem)', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = FinancialRepository();
      await repo.initialize();
      final g0 = repo.dataGeneration;
      repo.addTransaction(tx('a', 1));
      expect(repo.dataGeneration, g0);
      await repo.clearAllData();
      expect(repo.dataGeneration, greaterThan(g0));
      final g1 = repo.dataGeneration;
      repo.replaceAllFromCloud(transactions: const [], reminders: const [], budgets: const [], goals: const [], categoryOverrides: const {});
      expect(repo.dataGeneration, greaterThan(g1));
    });
  });
}
