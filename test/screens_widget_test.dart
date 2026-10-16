import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/auth_service.dart';
import 'package:krezio_ai/backend/services/pin_lock.dart';
import 'package:krezio_ai/frontend/features/auth/presentation/screens/login_screen.dart';
import 'package:krezio_ai/frontend/features/chat/presentation/screens/chat_screen.dart';
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
}
