import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/config/app_environment.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/auth_service.dart';
import 'package:krezio_ai/backend/services/pin_lock.dart';
import 'package:krezio_ai/frontend/features/dashboard/presentation/screens/dashboard_screen.dart';
import 'package:krezio_ai/frontend/features/dashboard/presentation/widgets/category_donut_chart.dart';
import 'package:krezio_ai/frontend/features/auth/presentation/screens/login_screen.dart';
import 'package:krezio_ai/frontend/features/chat/presentation/screens/chat_screen.dart';
import 'package:krezio_ai/frontend/features/homologation/presentation/screens/neural_inspector_screen.dart';
import 'package:krezio_ai/frontend/features/onboarding/onboarding_screen.dart';
import 'package:krezio_ai/frontend/features/security/lock_screen.dart';
import 'package:krezio_ai/frontend/features/transactions/presentation/screens/transactions_screen.dart';
import 'package:krezio_ai/frontend/features/transactions/presentation/widgets/add_transaction_modal.dart';
import 'package:krezio_ai/frontend/theme/krezio_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Testes de widget das telas principais (Fase 8.1): os fluxos rodam sem erro
/// de layout num celular pequeno (360 × 690).
class _FakeAuth extends Fake implements FirebaseAuth {}

Widget app(Widget home) => MaterialApp(theme: KrezioTheme.darkTheme, home: home);

FinancialRepository repoWith(List<FinancialTransaction> txs) {
  final r = FinancialRepository();
  r.replaceAllFromCloud(transactions: txs, reminders: [], budgets: r.budgets.toList(), goals: [], categoryOverrides: {});
  return r;
}

Future<void> phone(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 690);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('o botão de privacidade atualiza o saldo imediatamente', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final repository = FinancialRepository(seedDemo: false, persistChanges: false);
    repository.addTransaction(FinancialTransaction(
      id: 'salario',
      title: 'Salário',
      amount: 128450.90,
      type: TransactionType.income,
      category: 'salary',
      paymentMethod: 'pix',
      date: DateTime.now(),
    ));
    await phone(tester);
    await tester.pumpWidget(app(DashboardScreen(
      repository: repository,
      isDark: true,
      onNavigateToChat: () {},
      onNavigateToTransactions: () {},
    )));

    expect(find.text(r'R$ 128.450,90'), findsWidgets);
    await tester.tap(find.byTooltip('Ocultar valores'));
    await tester.pump();
    expect(find.text(r'R$ 128.450,90'), findsNothing);
    expect(find.text('••••'), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Valor oculto')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp(r'128\.450,90')), findsNothing);

    await tester.tap(find.byTooltip('Mostrar valores'));
    await tester.pump();
    expect(find.text(r'R$ 128.450,90'), findsWidgets);
  });

  testWidgets('a legenda fica abaixo da rosca no celular e ao lado na web', (tester) async {
    for (final width in [360.0, 720.0]) {
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: width,
            child: const CategoryDonutChart(
              categoryData: {'supermarket': 128450.90},
              isDark: true,
              totalLabel: 'Gastos do mês',
            ),
          ),
        ),
      ));
      final title = tester.getCenter(find.text('Gastos do mês'));
      final category = tester.getCenter(find.text('Supermercado'));
      expect(find.text('R\$ 128.450,90'), findsOneWidget);
      if (width == 360) {
        expect(category.dy, greaterThan(title.dy));
      } else {
        expect(category.dx, greaterThan(title.dx));
        expect((category.dy - title.dy).abs(), lessThan(35));
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('sugestão de gasto preenche o campo sem registrar em produção', (tester) async {
    await phone(tester);
    final initial = EnvironmentConfig.current;
    addTearDown(() => EnvironmentConfig.setEnvironment(initial));
    EnvironmentConfig.setEnvironment(AppEnvironment.production);
    final engine = LocalFinancialNlpEngine.fromJsonString(
      File('models/on_device/krezio_nlp_model.json').readAsStringSync(),
    );
    final repo = repoWith([]);
    await tester.pumpWidget(app(ChatScreen(
      engine: engine,
      repository: repo,
      onToggleTheme: () {},
      isDarkMode: true,
    )));
    await tester.tap(find.text('Registrar gasto'));
    await tester.pump();
    expect(find.text('Gastei 45,90 no mercado no Pix'), findsOneWidget);
    expect(repo.transactions, isEmpty);
    expect(find.text('NEURAL'), findsNothing);
    expect(find.text('Latência Local'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('login: cadastro só envia com senhas iguais e termos aceitos', (tester) async {
    await phone(tester);
    await tester.pumpWidget(app(LoginScreen(authService: AuthService(auth: _FakeAuth()), isDark: true)));
    expect(find.text('Entrar'), findsWidgets);

    await tester.tap(find.text('Não tenho conta — Criar uma'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Ana');
    await tester.enterText(fields.at(1), 'ana@exemplo.com');
    await tester.enterText(fields.at(2), 'senhaForte1');
    await tester.enterText(fields.at(3), 'senhaForte1');
    await tester.pump();

    ElevatedButton button() => tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Criar conta'));
    expect(button().onPressed, isNull, reason: 'sem aceitar os termos');
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(button().onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('formulário de lançamento: sem valor não salva; com valor salva', (tester) async {
    await phone(tester);
    FinancialTransaction? saved;
    await tester.pumpWidget(app(Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              builder: (_) => AddTransactionModal(isDark: true, onAdd: (t) => saved = t),
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    )));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Descrição / Estabelecimento'), 'Mercado');
    await tester.ensureVisible(find.text('Salvar Lançamento'));
    await tester.tap(find.text('Salvar Lançamento'));
    await tester.pump();
    expect(saved, isNull);
    expect(find.text('Por favor, informe a descrição e um valor válido.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5)); // o aviso some
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Valor (R\$)'), '50,90');
    await tester.ensureVisible(find.text('Salvar Lançamento'));
    await tester.tap(find.text('Salvar Lançamento'));
    await tester.pumpAndSettle();
    expect(saved!.title, 'Mercado');
    expect(saved!.amount, 50.9);
    expect(tester.takeException(), isNull);
  });

  testWidgets('extrato: agrupa por dia e a busca ignora acento', (tester) async {
    await phone(tester);
    final now = DateTime.now();
    final repo = repoWith([
      FinancialTransaction(
          id: '1', title: 'Açougue', amount: 80, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: now),
      FinancialTransaction(
          id: '2',
          title: 'Uber',
          amount: 30,
          type: TransactionType.expense,
          category: 'transport',
          paymentMethod: 'pix',
          date: now.subtract(const Duration(days: 1))),
    ]);
    await tester.pumpWidget(app(TransactionsScreen(repository: repo, isDark: true)));
    await tester.pumpAndSettle();
    expect(find.text('Hoje'), findsOneWidget);
    expect(find.text('Ontem'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'acougue');
    await tester.pumpAndSettle();
    expect(find.text('Açougue'), findsOneWidget);
    expect(find.text('Uber'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat: "gastei 50 no mercado no pix" vira lançamento', (tester) async {
    await phone(tester);
    final engine = LocalFinancialNlpEngine.fromJsonString(File('models/on_device/krezio_nlp_model.json').readAsStringSync());
    final repo = repoWith([]);
    await tester.pumpWidget(app(ChatScreen(engine: engine, repository: repo, onToggleTheme: () {}, isDarkMode: true)));
    await tester.pump();

    await tester.enterText(find.byType(TextField).last, 'gastei 50 no mercado no pix');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(seconds: 1));
    expect(repo.transactions.single.amount, 50);
    expect(repo.transactions.single.paymentMethod, 'pix');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('onboarding: pular conclui e guarda o aceite', (tester) async {
    await phone(tester);
    final repo = repoWith([]);
    var done = false;
    await tester.pumpWidget(app(OnboardingScreen(repository: repo, onDone: () => done = true)));
    expect(find.text('Suas finanças, sem planilha'), findsOneWidget);
    await tester.tap(find.text('Pular'));
    expect(done, isTrue);
    expect(repo.preference(OnboardingScreen.donePref), isNotNull);
    expect(repo.preference('legal_accepted'), startsWith('1.0|'));
  });

  testWidgets('tela de PIN: PIN certo desbloqueia', (tester) async {
    await phone(tester);
    final lock = PinLock(MemoryPinStore());
    await lock.setPin('2580', '2580');
    var unlocked = false;
    await tester.pumpWidget(app(LockScreen(lock: lock, onUnlocked: () => unlocked = true)));
    for (final d in ['2', '5', '8', '0']) {
      await tester.tap(find.text(d));
      await tester.pumpAndSettle();
    }
    expect(unlocked, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dar Enter no teclado envia o formulário de novo lançamento', (tester) async {
    await phone(tester);
    FinancialTransaction? saved;
    await tester.pumpWidget(app(Scaffold(
      body: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () => showModalBottomSheet(
            context: ctx,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => AddTransactionModal(
              isDark: true,
              onAdd: (tx) => saved = tx,
            ),
          ),
          child: const Text('Abrir modal'),
        ),
      ),
    )));
    await tester.tap(find.text('Abrir modal'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Descrição / Estabelecimento'), 'Café expresso');
    await tester.enterText(find.widgetWithText(TextField, 'Valor (R\$)'), '1200');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.title, 'Café expresso');
    expect(saved!.amount, 12.0);
  });

  testWidgets('categorias de lançamento condizem com Despesa vs Receita e Orçamentos fica na aba de Lançamentos', (tester) async {
    await phone(tester);
    await tester.pumpWidget(app(Scaffold(
      body: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () => showModalBottomSheet(
            context: ctx,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) => AddTransactionModal(
              isDark: true,
              onAdd: (_) {},
            ),
          ),
          child: const Text('Abrir modal'),
        ),
      ),
    )));
    await tester.tap(find.text('Abrir modal'));
    await tester.pumpAndSettle();

    // Em Despesa: Supermercado aparece, Salário não aparece
    expect(find.widgetWithText(ChoiceChip, 'Supermercado'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Salário'), findsNothing);

    // Ao trocar para Receita: Salário aparece, Supermercado não aparece
    await tester.tap(find.text('Receita'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Salário'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Supermercado'), findsNothing);
  });

  testWidgets('aba de lançamentos alterna entre Extrato e Orçamentos com filtros distribuídos', (tester) async {
    await phone(tester);
    final repo = FinancialRepository(seedDemo: true, persistChanges: false);
    await tester.pumpWidget(app(TransactionsScreen(repository: repo, isDark: true)));
    await tester.pumpAndSettle();

    expect(find.text('Extrato'), findsOneWidget);
    expect(find.text('Orçamentos'), findsOneWidget);

    await tester.tap(find.text('Orçamentos'));
    await tester.pumpAndSettle();

    expect(find.text('Teto de Gastos Mensal'), findsOneWidget);
    expect(find.text('Todos'), findsOneWidget);
    expect(find.text('No controle'), findsOneWidget);
    expect(find.text('Atenção'), findsOneWidget);
    expect(find.text('Estourados'), findsOneWidget);
  });

  testWidgets('modo de homologação: inspetor XAI renderiza todas as abas sem overflow no mobile e gera JSON válido', (tester) async {
    await phone(tester);
    final engine = LocalFinancialNlpEngine.fromJsonString(
      File('models/on_device/krezio_nlp_model.json').readAsStringSync(),
    );
    await tester.pumpWidget(app(NeuralInspectorScreen(
      engine: engine,
      initialQuery: 'asinei a netflx de 55 no cartao credito',
      isDark: true,
    )));
    await tester.pump();
    expect(find.text('NLP PIPELINE'), findsOneWidget);
    expect(find.text('HOMOLOGAÇÃO'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Tab 2: Softmax & XAI
    await tester.ensureVisible(find.text('Softmax & XAI'));
    await tester.tap(find.text('Softmax & XAI'));
    await tester.pump();
    expect(find.text('ML Softmax Bruto vs. Saída Pós-Regras'), findsOneWidget);
    expect(find.text('Pré-processamento, Typos & OOV'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Tab 3: Slots & Regras
    await tester.ensureVisible(find.text('Slots & Regras'));
    await tester.tap(find.text('Slots & Regras'));
    await tester.pump();
    expect(find.text('Árvore de Decisão & Extração de Slots'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Tab 4: Benchmark & Agenda
    await tester.ensureVisible(find.text('Benchmark & Agenda'));
    await tester.tap(find.text('Benchmark & Agenda'));
    await tester.pump();
    expect(find.text('Benchmark Golden Set On-Device'), findsOneWidget);
    expect(find.text('Pass Rate'), findsOneWidget);
    expect(find.text('Override Rate'), findsOneWidget);
    expect(find.text('Margem Δp'), findsOneWidget);
    expect(find.text('Zero-Vec Rate'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Tab 5: Trace JSON (valid JSON output)
    await tester.ensureVisible(find.text('Trace JSON'));
    await tester.tap(find.text('Trace JSON'));
    await tester.pump();
    final jsonTextWidget = tester.widget<SelectableText>(find.byType(SelectableText).first);
    final decoded = jsonDecode(jsonTextWidget.data!);
    expect(decoded, isA<Map<String, dynamic>>());
    expect(decoded['classifiers']['intent']['predicted'], isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat card mantém largura elegante (<= 420px) no desktop e zero overflow', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final engine = LocalFinancialNlpEngine.fromJsonString(File('models/on_device/krezio_nlp_model.json').readAsStringSync());
    final repo = repoWith([]);
    await tester.pumpWidget(app(ChatScreen(engine: engine, repository: repo, onToggleTheme: () {}, isDarkMode: true)));
    await tester.pump();

    await tester.enterText(find.byType(TextField).last, 'gastei 45,90 no mercado no pix');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(seconds: 1));

    final cardFinder = find.byKey(const ValueKey('chat-transaction-card'));
    expect(cardFinder, findsOneWidget);
    expect(tester.getSize(cardFinder).width, lessThanOrEqualTo(420.0));
    expect(find.text('DESPESA'), findsOneWidget);
    expect(find.text('Registrado'), findsOneWidget);
    expect(find.text('R\$ 45,90'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('chat: dividir conta exibe card limpo com a minha parte e cria lembrete a receber', (tester) async {
    await phone(tester);
    final engine = LocalFinancialNlpEngine.fromJsonString(File('models/on_device/krezio_nlp_model.json').readAsStringSync());
    final repo = repoWith([]);
    await tester.pumpWidget(app(ChatScreen(engine: engine, repository: repo, onToggleTheme: () {}, isDarkMode: true)));
    await tester.pump();

    await tester.enterText(find.byType(TextField).last, 'fui em um jantar, o total deu 320, dividimos em 3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(seconds: 1));
    await tester.drag(find.byType(ListView).last, const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(repo.transactions.single.title, 'Jantar');
    expect(repo.transactions.single.amount, 106.67);
    expect(repo.reminders.single.amount, 213.33);
    expect(find.byKey(const ValueKey('chat-transaction-card')), findsOneWidget);
    expect(find.text('Jantar'), findsOneWidget);
    expect(find.text('R\$ 106,67'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('transactions: botão Filtros abre modal com Período, Tipo de Lançamento e sem Margem de Valor', (tester) async {
    await phone(tester);
    final repo = repoWith([]);
    await tester.pumpWidget(app(TransactionsScreen(repository: repo, isDark: true)));
    await tester.pumpAndSettle();

    expect(find.text('Filtros'), findsOneWidget);
    expect(find.text('Margem de Valor'), findsNothing);
    expect(find.text('Categorias'), findsNothing);

    await tester.tap(find.text('Filtros'));
    await tester.pumpAndSettle();

    expect(find.text('Período'), findsOneWidget);
    expect(find.text('Tipo de Lançamento'), findsOneWidget);
    expect(find.text('Despesas'), findsOneWidget);
    expect(find.text('Receitas'), findsOneWidget);
    expect(find.text('Parceladas'), findsOneWidget);
    expect(find.text('Recorrentes'), findsOneWidget);
    expect(find.text('Margem de Valor (Gasto / Recebido)'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat: sugestões categorizadas com dropdowns populam o campo de texto', (tester) async {
    await phone(tester);
    final engine = LocalFinancialNlpEngine.fromJsonString(File('models/on_device/krezio_nlp_model.json').readAsStringSync());
    final repo = repoWith([]);
    await tester.pumpWidget(app(ChatScreen(engine: engine, repository: repo, onToggleTheme: () {}, isDarkMode: true)));
    await tester.pump();

    expect(find.text('Lançamentos'), findsOneWidget);
    await tester.tap(find.text('Lançamentos'));
    await tester.pumpAndSettle();

    expect(find.text('Almoço / restaurante'), findsOneWidget);
    await tester.tap(find.text('Almoço / restaurante'));
    await tester.pumpAndSettle();

    final input = tester.widget<TextField>(find.byType(TextField).last);
    expect(input.controller?.text, 'Paguei 58 no almoço no débito');
    expect(tester.takeException(), isNull);
  });
}
