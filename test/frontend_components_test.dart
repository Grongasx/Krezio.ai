import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/frontend/navigation/krezio_routes.dart';
import 'package:krezio_ai/frontend/theme/krezio_theme.dart';
import 'package:krezio_ai/frontend/widgets/krezio_components.dart';

Widget _app(Widget child, {ThemeData? theme}) =>
    MaterialApp(theme: theme ?? KrezioTheme.lightTheme, home: Scaffold(body: child));

void main() {
  group('KrezioMoneyField.parse', () {
    test('formatos brasileiros', () {
      expect(KrezioMoneyField.parse('80'), 80);
      expect(KrezioMoneyField.parse('12,5'), 12.5);
      expect(KrezioMoneyField.parse('1.234,56'), 1234.56);
      expect(KrezioMoneyField.parse('R\$ 1.500,00'), 1500);
      expect(KrezioMoneyField.parse(' 99.90 '), 99.9);
    });

    test('vazio, zero, negativo e lixo são recusados', () {
      for (final bad in ['', '0', '0,00', '-5', 'abc', ',', 'NaN']) {
        expect(KrezioMoneyField.parse(bad), isNull, reason: bad);
      }
    });
  });

  group('KrezioRoutes', () {
    test('cada aba tem uma rota e o índice volta certo', () {
      expect(KrezioRoutes.tabFor('/'), 0);
      expect(KrezioRoutes.tabFor('/extrato'), 1);
      expect(KrezioRoutes.tabFor('/chat'), 2);
      expect(KrezioRoutes.tabFor('/metas'), 3);
      expect(KrezioRoutes.tabFor('/ajustes'), 4);
    });

    test('rota desconhecida, vazia ou com query cai no lugar certo', () {
      expect(KrezioRoutes.tabFor('/nao-existe'), 0);
      expect(KrezioRoutes.tabFor(''), 0);
      expect(KrezioRoutes.tabFor(null), 0);
      expect(KrezioRoutes.tabFor('/chat?from=widget'), 2);
    });
  });

  group('showKrezioConfirmDialog', () {
    Future<bool?> open(WidgetTester tester, String tap) async {
      bool? result;
      await tester.pumpWidget(_app(Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              result = await showKrezioConfirmDialog(context, title: 'Limpar?', message: 'Apagar tudo?', confirmLabel: 'Limpar', danger: true),
          child: const Text('abrir'),
        ),
      )));
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      expect(find.text('Apagar tudo?'), findsOneWidget);
      await tester.tap(find.text(tap));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('confirmar devolve true', (tester) async {
      expect(await open(tester, 'Limpar'), isTrue);
    });

    testWidgets('cancelar devolve false', (tester) async {
      expect(await open(tester, 'Cancelar'), isFalse);
    });
  });

  testWidgets('formulário só fecha quando a validação passa', (tester) async {
    final c = TextEditingController();
    var saved = 0.0;
    await tester.pumpWidget(_app(Builder(
      builder: (context) => TextButton(
        onPressed: () => showKrezioFormDialog(
          context,
          title: 'Guardar',
          fields: [KrezioMoneyField(controller: c, label: 'Valor')],
          onConfirm: () {
            final v = KrezioMoneyField.parse(c.text);
            if (v == null) return false;
            saved = v;
            return true;
          },
        ),
        child: const Text('abrir'),
      ),
    )));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(find.text('Guardar'), findsOneWidget, reason: 'valor vazio não fecha');
    await tester.enterText(find.byType(TextField), '150,50');
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(find.text('Guardar'), findsNothing);
    expect(saved, 150.5);
  });

  testWidgets('estado vazio mostra título, mensagem e ação', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_app(KrezioEmptyState(
      icon: Icons.receipt_long_outlined,
      title: 'Nenhum lançamento ainda',
      message: 'Fale com o César',
      actionLabel: 'Abrir chat',
      onAction: () => tapped = true,
    )));
    expect(find.text('Nenhum lançamento ainda'), findsOneWidget);
    expect(find.text('Fale com o César'), findsOneWidget);
    await tester.tap(find.text('Abrir chat'));
    expect(tapped, isTrue);
  });

  testWidgets('estado de erro oferece "tentar de novo"', (tester) async {
    var retried = false;
    await tester.pumpWidget(_app(KrezioErrorState(message: 'Falhou', onRetry: () => retried = true)));
    expect(find.text('Algo deu errado'), findsOneWidget);
    await tester.tap(find.text('Tentar de novo'));
    expect(retried, isTrue);
  });

  testWidgets('componentes funcionam no tema escuro', (tester) async {
    await tester.pumpWidget(_app(const Column(children: [
      KrezioCard(child: Text('card')),
      KrezioEmptyState(icon: Icons.flag_outlined, title: 'vazio', compact: true),
    ]), theme: KrezioTheme.darkTheme));
    expect(find.text('card'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('splash mostra a marca sem texto pequeno', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: KrezioTheme.darkTheme, home: const KrezioSplash()));
    final name = tester.widget<Text>(find.text('Krezio.ai'));
    expect(name.style!.fontSize, KrezioFont.headline);
  });
}
