import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/models/financial_transaction.dart';
import '../widgets/metric_summary_card.dart';
import '../widgets/ai_insight_card.dart';
import '../widgets/category_donut_chart.dart';
import '../../../transactions/presentation/widgets/transaction_list_tile.dart';
import '../../../transactions/presentation/widgets/add_transaction_modal.dart';

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
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: KrezioColors.aiPurple.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.auto_awesome, color: KrezioColors.aiPurple, size: 20),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Krezio.ai',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: primaryTextColor,
                          ),
                        ),
                        Text(
                          'Gestão Inteligente On-Device',
                          style: TextStyle(
                            fontSize: 10,
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                    const SizedBox(height: 12),

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
                        const SizedBox(width: 10),
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
                    const SizedBox(height: 16),

                    // 3. Proactive Alerts (César speaks up on its own — budgets near/over
                    // limit, bills due within days, overdue debts) — shown before the
                    // passive insight card since these are actionable, time-sensitive.
                    if (proactiveAlerts.isNotEmpty) ...[
                      ...proactiveAlerts.map((alert) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _buildProactiveAlertCard(alert, bgSurface, borderColor),
                          )),
                      const SizedBox(height: 6),
                    ],

                    // 3.5 AI Proactive Insight Card
                    AiInsightCard(
                      insightText: aiInsight,
                      isDark: isDark,
                      onAskAi: onNavigateToChat,
                    ),
                    const SizedBox(height: 20),

                    // 4. Category Spending Donut Chart Card
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: bgSurface,
                        borderRadius: KrezioTheme.borderRadius,
                        border: Border.all(color: borderColor),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Gastos por Categoria',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: primaryTextColor,
                                ),
                              ),
                              Text(
                                'Este Mês',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: secondaryTextColor,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          CategoryDonutChart(
                            categoryData: categoryExpenses,
                            isDark: isDark,
                            categoryNames: {for (final b in repository.budgets) b.category: b.name},
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 5. Upcoming Recurring Bills Alert
                    if (upcomingBills.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: bgSurface,
                          borderRadius: KrezioTheme.borderRadius,
                          border: Border.all(color: borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.event_repeat, size: 16, color: KrezioColors.aiPurple),
                                const SizedBox(width: 6),
                                Text(
                                  'Contas Fixas & Recorrências',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: primaryTextColor,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            ...upcomingBills.map((b) {
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '${b.title} (${b.dueLabel})',
                                      style: TextStyle(fontSize: 12, color: primaryTextColor),
                                    ),
                                    Text(
                                      'R\$ ${b.amount.toStringAsFixed(2).replaceAll('.', ',')}',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: primaryTextColor),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // 5.5 Reminders & Receivables Section
                    if (repository.reminders.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: bgSurface,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Icon(Icons.notifications_active_outlined, size: 16, color: KrezioColors.friendlyOrange),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Lembretes & Contas a Receber',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                        color: primaryTextColor,
                                      ),
                                    ),
                                  ],
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: KrezioColors.friendlyOrange.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    '${repository.reminders.where((r) => !r.isCompleted).length} ativos',
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: KrezioColors.friendlyOrange),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            ...repository.reminders.map((r) {
                              final dayStr = r.targetDate.day.toString().padLeft(2, '0');
                              final monthStr = r.targetDate.month.toString().padLeft(2, '0');
                              final amountStr = r.amount != null
                                  ? 'R\$ ${r.amount!.toStringAsFixed(2).replaceAll(".", ",")}'
                                  : '';

                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
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
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            r.title,
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: r.isCompleted ? secondaryTextColor : primaryTextColor,
                                              decoration: r.isCompleted ? TextDecoration.lineThrough : null,
                                            ),
                                          ),
                                          if (r.notes != null)
                                            Text(
                                              r.notes!,
                                              style: TextStyle(fontSize: 10, color: secondaryTextColor),
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
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: r.isCompleted ? secondaryTextColor : KrezioColors.friendlyOrange,
                                            ),
                                          ),
                                        Text(
                                          '$dayStr/$monthStr',
                                          style: TextStyle(fontSize: 10, color: secondaryTextColor),
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
                      const SizedBox(height: 20),
                    ],

                    // 6. Recent Activity Section
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Últimos Lançamentos',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: primaryTextColor,
                          ),
                        ),
                        TextButton(
                          onPressed: onNavigateToTransactions,
                          child: const Text(
                            'Ver Extrato',
                            style: TextStyle(fontSize: 12, color: KrezioColors.aiPurple, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (recentTxs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            'Nenhum lançamento registrado.',
                            style: TextStyle(color: secondaryTextColor, fontSize: 13),
                          ),
                        ),
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgSurface,
        borderRadius: KrezioTheme.borderRadius,
        border: Border.all(color: accent.withOpacity(0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              alert.message,
              style: TextStyle(fontSize: 12, color: isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText),
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
      ),
    );
  }
}
