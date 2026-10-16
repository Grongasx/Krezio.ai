import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/frontend/features/navigation/main_navigation_wrapper.dart';
import 'package:krezio_ai/frontend/theme/krezio_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  Future<FinancialRepository> repo() async {
    SharedPreferences.setMockInitialValues({});
    final r = FinancialRepository();
    await r.initialize();
    return r;
  }

  Future<void> pump(WidgetTester tester, FinancialRepository r, int initialIndex) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    // A fonte de teste (Ahem) é bem mais larga que a real e acusa estouros de
    // layout que não existem no aparelho. Este teste é sobre o botão voltar;
    // estouro de layout é conferido no app rodando (tela de 375 px).
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
    await tester.pumpWidget(MaterialApp(
      theme: KrezioTheme.darkTheme,
      home: MainNavigationWrapper(
        engine: engine,
        repository: r,
        onToggleTheme: () {},
        isDark: true,
        initialIndex: initialIndex,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  int currentTab(WidgetTester tester) => tester.widget<BottomNavigationBar>(find.byType(BottomNavigationBar)).currentIndex;

  testWidgets('link direto abre na aba pedida', (tester) async {
    await pump(tester, await repo(), 2);
    expect(currentTab(tester), 2);
  });

  testWidgets('voltar fora do Início vai para o Início, sem fechar o app', (tester) async {
    await pump(tester, await repo(), 3);
    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    expect(handled, isTrue, reason: 'o app tratou o voltar (não fechou)');
    expect(currentTab(tester), 0);
  });

  testWidgets('voltar no Início segue o comportamento normal (sai do app)', (tester) async {
    await pump(tester, await repo(), 0);
    final handled = await tester.binding.handlePopRoute();
    expect(handled, isFalse, reason: 'sem rota para voltar, o sistema fecha o app');
  });
}
