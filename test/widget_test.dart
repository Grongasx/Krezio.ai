import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:krezio_ai/core/models/financial_transaction.dart';
import 'package:krezio_ai/core/models/budget_category.dart';
import 'package:krezio_ai/core/repositories/financial_repository.dart';
import 'package:krezio_ai/features/dashboard/presentation/widgets/metric_summary_card.dart';
import 'package:krezio_ai/features/dashboard/presentation/widgets/ai_insight_card.dart';

void main() {
  testWidgets('MetricSummaryCard renders amount and title properly', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MetricSummaryCard(
            title: 'Saldo Geral',
            amount: 2500.50,
            icon: Icons.account_balance_wallet_outlined,
            iconColor: Colors.green,
            isDark: true,
            isLarge: true,
          ),
        ),
      ),
    );

    expect(find.text('Saldo Geral'), findsOneWidget);
    expect(find.text('R\$ 2500,50'), findsOneWidget);
  });

  testWidgets('AiInsightCard renders insight and button', (WidgetTester tester) async {
    bool asked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiInsightCard(
            insightText: 'Você economizou 40% este mês.',
            isDark: false,
            onAskAi: () => asked = true,
          ),
        ),
      ),
    );

    expect(find.text('Insight do Krezio.ai'), findsOneWidget);
    expect(find.text('Você economizou 40% este mês.'), findsOneWidget);
    expect(find.text('Conversar com a IA'), findsOneWidget);

    await tester.tap(find.text('Conversar com a IA'));
    expect(asked, true);
  });
}
