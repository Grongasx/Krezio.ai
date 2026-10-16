import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/models/financial_transaction.dart';
import '../widgets/metric_summary_card.dart';
import '../widgets/ai_insight_card.dart';
import '../widgets/category_donut_chart.dart';
import '../../../transactions/presentation/widgets/transaction_list_tile.dart';
import '../../../transactions/presentation/widgets/add_transaction_modal.dart';
import '../../../reminders/presentation/screens/open_items_screen.dart';

class DashboardScreen extends StatelessWidget {
  final FinancialRepository repository;
  final bool isDark;
  final VoidCallback onNavigateToChat;
  final VoidCallback onNavigateToTransactions;

  const DashboardScreen({
    super.key,
    required this.repository,
    required this.isDark,
    required this.onNavigateToChat,
    required this.onNavigateToTransactions,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: repository,
      builder: (context, _) {
        final totalBalance = repository.totalBalance;
        final monthIncome = repository.monthIncome;
        final monthExpense = repository.monthExpense;
        final categoryExpenses = repository.categoryExpensesThisMonth;
        final recentTxs = repository.recentTransactions;
        final aiInsight = repository.generateAiInsight();
        final upcomingBills = repository.upcomingRecurrences;
        final proactiveAlerts = repository.getProactiveAlerts();

        final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
        final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
        final primaryTextColor = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
        final secondaryTextColor = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

        return Scaffold(
          body: CustomScrollView(
            slivers: [
              // Custom App Header
              SliverAppBar(
                floating: true,
                pinned: false,
                backgroundColor: isDark ? KrezioColors.darkBackground : KrezioColors.lightBackground,
                elevation: 0,
                title: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(KrezioSpace.sm),
                      decoration: BoxDecoration(
                        color: KrezioColors.aiPurple.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.auto_awesome, color: KrezioColors.aiPurple, size: 20),
                    ),
                    const SizedBox(width: KrezioSpace.md),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Krezio.ai',
                          style: TextStyle(
                            fontSize: KrezioFont.bodyLarge,
                            fontWeight: FontWeight.bold,
                            color: primaryTextColor,
                          ),
                        ),
                        Text(
                          'Gestão Inteligente On-Device',
                          style: TextStyle(
                            fontSize: KrezioFont.micro,
                            color: secondaryTextColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline, color: KrezioColors.aiPurple),
                    tooltip: 'Novo Lançamento',
                    onPressed: () => _openAddModal(context),
                  ),
                ],
              ),

              // Body Content
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.sm),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    // 1. Total Balance Hero Card
                    MetricSummaryCard(
                      title: 'Saldo Líquido Geral',
                      amount: totalBalance,
                      icon: Icons.account_balance_wallet_outlined,
                      iconColor: totalBalance >= 0 ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange,
                      isDark: isDark,
                      isLarge: true,
                    ),
                    const SizedBox(height: KrezioSpace.md),

                    // 2. Month Income & Month Expense Split
                    Row(
                      children: [
                        Expanded(
                          child: MetricSummaryCard(
                            title: 'Entradas (Mês)',
                            amount: monthIncome,
                            icon: Icons.arrow_downward,
                            iconColor: KrezioColors.emeraldGreen,
                            isDark: isDark,
                          ),
                        ),
                        const SizedBox(width: KrezioSpace.md),
                        Expanded(
                          child: MetricSummaryCard(
                            title: 'Saídas (Mês)',
                            amount: monthExpense,
                            icon: Icons.arrow_upward,
                            iconColor: KrezioColors.friendlyOrange,
                            isDark: isDark,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: KrezioSpace.lg),

                    // 3. Proactive Alerts (César speaks up on its own — budgets near/over
                    // limit, bills due within days, overdue debts) — shown before the
                    // passive insight card since these are actionable, time-sensitive.
                    if (proactiveAlerts.isNotEmpty) ...[
                      ...proactiveAlerts.map((alert) => Padding(
                            padding: const EdgeInsets.only(bottom: KrezioSpace.md),
                            child: _buildProactiveAlertCard(alert, bgSurface, borderColor),
                          )),
                      const SizedBox(height: KrezioSpace.sm),
                    ],

                    // 3.5 AI Proactive Insight Card
                    AiInsightCard(
                      insightText: aiInsight,
                      isDark: isDark,
                      onAskAi: onNavigateToChat,
                    ),
                    const SizedBox(height: KrezioSpace.xl),

                    // 4. Category Spending Donut Chart Card
                    KrezioCard(
                      padding: const EdgeInsets.all(KrezioSpace.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Gastos por Categoria',
                                style: TextStyle(
                                  fontSize: KrezioFont.body,
                                  fontWeight: FontWeight.bold,
                                  color: primaryTextColor,
                                ),
                              ),
                              Text(
                                'Este Mês',
                                style: TextStyle(
                                  fontSize: KrezioFont.caption,
                                  color: secondaryTextColor,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: KrezioSpace.lg),
                          CategoryDonutChart(
                            categoryData: categoryExpenses,
                            isDark: isDark,
                            categoryNames: {for (final b in repository.budgets) b.category: b.name},
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: KrezioSpace.xl),

                    // 5. Upcoming Recurring Bills Alert
                    if (upcomingBills.isNotEmpty) ...[
                      KrezioCard(
                        padding: const EdgeInsets.all(KrezioSpace.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.event_repeat, size: 16, color: KrezioColors.aiPurple),
                                const SizedBox(width: KrezioSpace.sm),
                                Text(
                                  'Contas Fixas & Recorrências',
                                  style: TextStyle(
                                    fontSize: KrezioFont.bodySmall,
                                    fontWeight: FontWeight.bold,
                                    color: primaryTextColor,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: KrezioSpace.md),
                            ...upcomingBills.map((b) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: KrezioSpace.xs),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '${b.title} (${b.dueLabel})',
                                      style: TextStyle(fontSize: KrezioFont.small, color: primaryTextColor),
                                    ),
                                    Text(
                                      'R\$ ${b.amount.toStringAsFixed(2).replaceAll('.', ',')}',
                                      style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: primaryTextColor),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                      const SizedBox(height: KrezioSpace.xl),
                    ],

                    // 5.5 Reminders & Receivables Section
                    if (repository.reminders.isNotEmpty) ...[
                      KrezioCard(
                        padding: const EdgeInsets.all(KrezioSpace.lg),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.notifications_active_outlined, size: 16, color: KrezioColors.friendlyOrange),
                                    const SizedBox(width: KrezioSpace.sm),
                                    Text(
                                      'Lembretes & Contas a Receber',
                                      style: TextStyle(
                                        fontSize: KrezioFont.bodySmall,
                                        fontWeight: FontWeight.bold,
                                        color: primaryTextColor,
                                      ),
                                    ),
                                  ],
                                ),
                                const Spacer(),
                                TextButton(
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => OpenItemsScreen(repository: repository, isDark: isDark)),
                                  ),
                                  child: const Text('Ver tudo', style: TextStyle(fontSize: KrezioFont.small)),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.sm, vertical: KrezioSpace.hair),
                                  decoration: BoxDecoration(
                                    color: KrezioColors.friendlyOrange.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${repository.reminders.where((r) => !r.isCompleted).length} ativos',
                                    style: const TextStyle(fontSize: KrezioFont.micro, fontWeight: FontWeight.bold, color: KrezioColors.friendlyOrange),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: KrezioSpace.md),
                            ...repository.reminders.map((r) {
                              final dayStr = r.targetDate.day.toString().padLeft(2, '0');
                              final monthStr = r.targetDate.month.toString().padLeft(2, '0');
                              final amountStr = r.amount != null
                                  ? 'R\$ ${r.amount!.toStringAsFixed(2).replaceAll(".", ",")}'
                                  : '';

                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: KrezioSpace.xs),
                                child: Row(
                                  children: [
                                    InkWell(
                                      onTap: () => repository.toggleReminderCompleted(r.id),
                                      borderRadius: BorderRadius.circular(4),
                                      child: Icon(
                                        r.isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
                                        size: 18,
                                        color: r.isCompleted ? KrezioColors.emeraldGreen : secondaryTextColor,
                                      ),
                                    ),
                                    const SizedBox(width: KrezioSpace.sm),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            r.title,
                                            style: TextStyle(
                                              fontSize: KrezioFont.small,
                                              fontWeight: FontWeight.w600,
                                              color: r.isCompleted ? secondaryTextColor : primaryTextColor,
                                              decoration: r.isCompleted ? TextDecoration.lineThrough : null,
                                            ),
                                          ),
                                          if (r.notes != null)
                                            Text(
                                              r.notes!,
                                              style: TextStyle(fontSize: KrezioFont.micro, color: secondaryTextColor),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                        ],
                                      ),
                                    ),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        if (amountStr.isNotEmpty)
                                          Text(
                                            amountStr,
                                            style: TextStyle(
                                              fontSize: KrezioFont.small,
                                              fontWeight: FontWeight.bold,
                                              color: r.isCompleted ? secondaryTextColor : KrezioColors.friendlyOrange,
                                            ),
                                          ),
                                        Text(
                                          '$dayStr/$monthStr',
                                          style: TextStyle(fontSize: KrezioFont.micro, color: secondaryTextColor),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                      const SizedBox(height: KrezioSpace.xl),
                    ],

                    // 6. Recent Activity Section
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Últimos Lançamentos',
                          style: TextStyle(
                            fontSize: KrezioFont.body,
                            fontWeight: FontWeight.bold,
                            color: primaryTextColor,
                          ),
                        ),
                        TextButton(
                          onPressed: onNavigateToTransactions,
                          child: const Text(
                            'Ver Extrato',
                            style: TextStyle(fontSize: KrezioFont.small, color: KrezioColors.aiPurple, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: KrezioSpace.xs),
                    if (recentTxs.isEmpty)
                      const KrezioEmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: 'Nenhum lançamento ainda',
                        message: 'Fale com o César: "gastei 50 no mercado no pix"',
                        compact: true,
                      )
                    else
                      ...recentTxs.map((tx) {
                        return TransactionListTile(
                          transaction: tx,
                          isDark: isDark,
                          onDelete: () => repository.deleteTransaction(tx.id),
                          onTap: () => _openEditModal(context, tx),
                        );
                      }),
                    const SizedBox(height: 40),
                  ]),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildProactiveAlertCard(ProactiveAlert alert, Color bgSurface, Color borderColor) {
    final Color accent;
    final IconData icon;
    switch (alert.severity) {
      case ProactiveAlertSeverity.critical:
        accent = KrezioColors.friendlyOrange;
        icon = Icons.warning_amber_rounded;
        break;
      case ProactiveAlertSeverity.warning:
        accent = KrezioColors.friendlyOrange;
        icon = Icons.notifications_active_outlined;
        break;
      case ProactiveAlertSeverity.info:
        accent = KrezioColors.aiPurple;
        icon = Icons.lightbulb_outline;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(KrezioSpace.md),
      decoration: BoxDecoration(
        color: bgSurface,
        borderRadius: KrezioTheme.borderRadius,
        border: Border.all(color: accent.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: KrezioSpace.md),
          Expanded(
            child: Text(
              alert.message,
              style: TextStyle(fontSize: KrezioFont.small, color: isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText),
            ),
          ),
        ],
      ),
    );
  }

  void _openAddModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddTransactionModal(
        isDark: isDark,
        onAdd: (tx) => repository.addTransaction(tx),
        customCategories: repository.budgets.where((b) => b.isCustom).toList(),
        accounts: repository.activeAccounts,
      ),
    );
  }

  void _openEditModal(BuildContext context, FinancialTransaction tx) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddTransactionModal(
        isDark: isDark,
        initialTransaction: tx,
        onAdd: (updated) => repository.updateTransaction(updated),
        customCategories: repository.budgets.where((b) => b.isCustom).toList(),
        accounts: repository.activeAccounts,
      ),
    );
  }
}
