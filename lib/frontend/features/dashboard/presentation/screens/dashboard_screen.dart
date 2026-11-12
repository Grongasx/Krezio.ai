import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../widgets/ledger_undo.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/models/financial_transaction.dart';
import '../widgets/metric_summary_card.dart';
import '../widgets/ai_insight_card.dart';
import '../widgets/category_donut_chart.dart';
import '../../../transactions/presentation/widgets/transaction_list_tile.dart';
import '../../../transactions/presentation/widgets/add_transaction_modal.dart';
import '../../../reminders/presentation/screens/open_items_screen.dart';
import '../../../../../backend/services/money.dart';

class DashboardScreen extends StatelessWidget {
  final FinancialRepository repository;
  final bool isDark;
  final VoidCallback onNavigateToChat;
  final VoidCallback onNavigateToTransactions;
  final ValueChanged<String>? onNavigateToBudgets;
  static const _hideAmounts = 'dashboard_hide_amounts';

  const DashboardScreen({
    super.key,
    required this.repository,
    required this.isDark,
    required this.onNavigateToChat,
    required this.onNavigateToTransactions,
    this.onNavigateToBudgets,
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
        final hideAmounts = repository.preference(_hideAmounts) == 'true';

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
                    Expanded(
                      child: Column(
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
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: KrezioFont.micro,
                              color: secondaryTextColor,
                            ),
                          ),
                        ],
                      ),
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
                    // 1. Total Balance Hero Card (with embedded privacy toggle)
                    MetricSummaryCard(
                      title: 'Saldo Líquido Geral',
                      amount: totalBalance,
                      icon: Icons.account_balance_wallet_outlined,
                      iconColor: totalBalance >= 0 ? KrezioColors.emeraldGreen : KrezioColors.friendlyOrange,
                      isDark: isDark,
                      isLarge: true,
                      hideAmount: hideAmounts,
                      onTogglePrivacy: () => repository.setPreference(
                        _hideAmounts,
                        (!hideAmounts).toString(),
                        notify: true,
                      ),
                    ),
                    const SizedBox(height: KrezioSpace.md),

                    // 2. Month Income & Month Expense Split
                    Row(
                      children: [
                        Expanded(
                          child: MetricSummaryCard(
                            title: 'Entradas (Mês)',
                            amount: monthIncome,
                            hideAmount: hideAmounts,
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
                            hideAmount: hideAmounts,
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
                            child: _buildProactiveAlertCard(context, alert, bgSurface, hideAmounts),
                          )),
                      const SizedBox(height: KrezioSpace.sm),
                    ],

                    // 3.5 AI Proactive Insight Card
                    AiInsightCard(
                      insightText: hideAmounts ? 'Valores ocultos no Início.' : aiInsight,
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
                              Expanded(
                                child: Text(
                                  'Gastos por Categoria',
                                  style: TextStyle(
                                    fontSize: KrezioFont.body,
                                    fontWeight: FontWeight.bold,
                                    color: primaryTextColor,
                                  ),
                                ),
                              ),
                              const SizedBox(width: KrezioSpace.sm),
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
                          if (hideAmounts)
                            const Center(child: Text('Valores do gráfico ocultos'))
                          else CategoryDonutChart(
                            totalLabel: 'Gastos do mês',
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
                              final isIncome = b.type == TransactionType.income;
                              final sign = isIncome ? '+ ' : '- ';
                              final valColor = isIncome ? KrezioColors.emeraldGreen : KrezioColors.budgetOver;
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: KrezioSpace.xs),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${b.title} (${b.dueLabel})',
                                        style: TextStyle(fontSize: KrezioFont.small, color: primaryTextColor),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: KrezioSpace.sm),
                                    Text(
                                      hideAmounts ? 'Valor oculto' : '$sign${Money.brl(b.amount)}',
                                      style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: valColor),
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
                              children: [
                                const Icon(Icons.notifications_active_outlined, size: 16, color: KrezioColors.friendlyOrange),
                                const SizedBox(width: KrezioSpace.sm),
                                Expanded(
                                  child: Text(
                                    'Lembretes & Contas a Receber',
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: KrezioFont.bodySmall,
                                      fontWeight: FontWeight.bold,
                                      color: primaryTextColor,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: KrezioSpace.xs),
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
                                TextButton(
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.sm),
                                  ),
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => OpenItemsScreen(repository: repository, isDark: isDark)),
                                  ),
                                  child: const Text('Ver tudo', style: TextStyle(fontSize: KrezioFont.small)),
                                ),
                              ],
                            ),
                            const SizedBox(height: KrezioSpace.md),
                            ...repository.reminders.take(4).map((r) {
                              final dayStr = r.targetDate.day.toString().padLeft(2, '0');
                              final monthStr = r.targetDate.month.toString().padLeft(2, '0');
                              final amountStr = r.amount != null
                                  ? (hideAmounts ? 'Valor oculto' : '${r.amountPrefix}${Money.brl(r.amount!)}')
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
                                        color: r.isCompleted ? KrezioColors.emeraldGreen : r.amountColor,
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
                                              color: r.isCompleted ? secondaryTextColor : r.amountColor,
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
                          key: ValueKey(tx.id),
                          transaction: tx,
                          isDark: isDark,
                          hideAmount: hideAmounts,
                          onDelete: () => deleteLedgerTransaction(context, repository, tx.id),
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

  Widget _buildProactiveAlertCard(BuildContext context, ProactiveAlert alert, Color bgSurface, bool hideAmounts) {
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

    final budget = alert.target == ProactiveAlertTarget.budget;
    final bill = alert.target == ProactiveAlertTarget.bill || alert.target == ProactiveAlertTarget.recurringTransaction;
    final label = budget ? 'Ver orçamento' : (bill ? 'Ver conta' : 'Ver pendência');
    final summary = budget ? 'Alerta de orçamento' : (bill ? 'Conta perto do vencimento' : 'Pendência em atraso');

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(hideAmounts ? summary : alert.message),
                TextButton(
                  onPressed: () => _openAlert(context, alert),
                  child: Text(label),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openAlert(BuildContext context, ProactiveAlert alert) {
    if (alert.target == ProactiveAlertTarget.budget) {
      onNavigateToBudgets?.call(alert.recordId);
      return;
    }
    if (alert.target == ProactiveAlertTarget.recurringTransaction) {
      for (final transaction in repository.transactions) {
        if (transaction.id != alert.recordId) continue;
        _openEditModal(context, transaction);
        return;
      }
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => OpenItemsScreen(
        repository: repository,
        isDark: isDark,
        focusId: alert.recordId,
        showDebtsFirst: alert.target == ProactiveAlertTarget.debt,
      ),
    ));
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
