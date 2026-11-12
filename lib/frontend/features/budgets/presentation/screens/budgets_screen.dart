import 'package:flutter/material.dart';
import '../../../../../ai/chat_action_history.dart';
import '../../../../../backend/services/money.dart';
import '../../../../widgets/ledger_undo.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/models/financial_goal.dart';

/// Cofrinhos tab. The Orçamentos (category limits) now live in the
/// Lançamentos tab (see BudgetsView).
class BudgetsScreen extends StatefulWidget {
  final FinancialRepository repository;
  final bool isDark;

  const BudgetsScreen({
    super.key,
    required this.repository,
    required this.isDark,
  });

  @override
  State<BudgetsScreen> createState() => _BudgetsScreenState();
}

class _BudgetsScreenState extends State<BudgetsScreen> {
  FinancialRepository get repository => widget.repository;
  bool get isDark => widget.isDark;

  @override
  Widget build(BuildContext context) {
    final primaryTextColor = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;

    return AnimatedBuilder(
      animation: repository,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            backgroundColor: isDark ? KrezioColors.darkBackground : KrezioColors.lightBackground,
            elevation: 0,
            title: Text(
              'Cofrinhos',
              style: TextStyle(fontSize: KrezioFont.title, fontWeight: FontWeight.bold, color: primaryTextColor),
            ),
          ),
          floatingActionButton: FloatingActionButton(
            backgroundColor: KrezioColors.aiPurple,
            tooltip: 'Novo Cofrinho',
            onPressed: () => _showAddGoalDialog(context),
            child: const Icon(Icons.add, color: Colors.white),
          ),
          body: _buildGoalsTab(context),
        );
      },
    );
  }

  /// Deleting a Cofrinho asks first (it was one tap away from the + button).
  Future<void> _removeGoal(BuildContext context, FinancialGoal goal) async {
    final ok = await showKrezioConfirmDialog(
      context,
      title: 'Apagar o cofrinho ${goal.title}?',
      message: goal.savedAmount > 0
          ? 'Ele tem ${Money.brl(goal.savedAmount)} guardados. Se quiser o dinheiro de volta no saldo, use "Resgatar" antes.'
          : 'Você pode desfazer logo em seguida.',
      confirmLabel: 'Apagar',
    );
    if (ok != true || !context.mounted) return;
    final undo = repository.deleteGoalWithUndo(goal.id);
    if (undo == null) return;
    showLedgerUndo(context, repository, ChatAction.restoration((_) => undo(), 'Cofrinho restaurado.'), 'Cofrinho apagado.');
  }

  // ── COFRINHOS (METAS COM DESCONTO DO SALDO LÍQUIDO COMO DESPESA) ──

  Widget _buildGoalsTab(BuildContext context) {
    final goals = repository.goals;
    final primaryTextColor = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryTextColor = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

    if (goals.isEmpty) {
      return const KrezioEmptyState(
        icon: Icons.savings_outlined,
        title: 'Nenhum cofrinho ainda',
        message: 'Toque no + para criar um Cofrinho.\nO valor guardado sai do seu saldo líquido como despesa para ficar protegido!',
      );
    }

    final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
    final totalSaved = goals.fold<double>(0.0, (s, g) => s + g.savedAmount);
    final totalTarget = goals.fold<double>(0.0, (s, g) => s + g.targetAmount);

    return ListView(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      children: [
        KrezioCard(
          padding: const EdgeInsets.all(KrezioSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.savings_outlined, color: KrezioColors.emeraldGreen, size: 20),
                  const SizedBox(width: KrezioSpace.sm),
                  Text(
                    'Total Guardado nos Cofrinhos',
                    style: TextStyle(fontSize: KrezioFont.bodySmall, fontWeight: FontWeight.w600, color: secondaryTextColor),
                  ),
                ],
              ),
              const SizedBox(height: KrezioSpace.sm),
              Row(
                children: [
                  Text(
                    Money.brl(totalSaved),
                    style: TextStyle(fontSize: KrezioFont.headline, fontWeight: FontWeight.bold, color: primaryTextColor),
                  ),
                  Text(
                    ' / ${Money.brl(totalTarget)}',
                    style: TextStyle(fontSize: KrezioFont.body, color: secondaryTextColor),
                  ),
                ],
              ),
              const SizedBox(height: KrezioSpace.xs),
              Text(
                'Valores aplicados saem do saldo líquido total como despesa.',
                style: TextStyle(fontSize: KrezioFont.caption, color: secondaryTextColor),
              ),
            ],
          ),
        ),
        const SizedBox(height: KrezioSpace.lg),
        for (int index = 0; index < goals.length; index++)
          _buildGoalCard(
            context,
            goals[index],
            goals[index].colorFor(index),
            bgSurface,
            borderColor,
            primaryTextColor,
            secondaryTextColor,
          ),
      ],
    );
  }

  Widget _buildGoalCard(
    BuildContext context,
    FinancialGoal goal,
    Color color,
    Color bgSurface,
    Color borderColor,
    Color primaryTextColor,
    Color secondaryTextColor,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: KrezioSpace.md),
      padding: const EdgeInsets.all(KrezioSpace.lg),
      decoration: BoxDecoration(
        color: bgSurface,
        borderRadius: KrezioTheme.borderRadius,
        border: Border.all(color: goal.isCompleted ? KrezioColors.emeraldGreen : borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(KrezioSpace.sm),
                decoration: BoxDecoration(color: color.withOpacity(0.12), shape: BoxShape.circle),
                child: Icon(goal.isCompleted ? Icons.check_circle : Icons.savings_outlined, color: color, size: 16),
              ),
              const SizedBox(width: KrezioSpace.md),
              Expanded(
                child: Text(
                  goal.title,
                  style: TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold, color: primaryTextColor),
                ),
              ),
              if (goal.savedAmount > 0)
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  color: KrezioColors.friendlyOrange,
                  tooltip: 'Resgatar do Cofrinho',
                  onPressed: () => _showWithdrawDialog(context, goal),
                ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 20),
                color: KrezioColors.emeraldGreen,
                tooltip: 'Guardar no Cofrinho',
                onPressed: () => _showContributeDialog(context, goal),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                color: secondaryTextColor,
                onPressed: () => _removeGoal(context, goal),
              ),
            ],
          ),
          const SizedBox(height: KrezioSpace.md),
          Text(
            '${Money.brl(goal.savedAmount)} guardados de ${Money.brl(goal.targetAmount)}',
            style: TextStyle(fontSize: KrezioFont.small, color: secondaryTextColor),
          ),
          const SizedBox(height: KrezioSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: goal.progress,
              minHeight: 8,
              backgroundColor: isDark ? KrezioColors.darkBackground : const Color(0xFFE5E7EB),
              valueColor: AlwaysStoppedAnimation<Color>(goal.isCompleted ? KrezioColors.emeraldGreen : color),
            ),
          ),
          if (goal.isCompleted) ...[
            const SizedBox(height: KrezioSpace.sm),
            const Text('🎉 Cofrinho completo!', style: TextStyle(fontSize: KrezioFont.caption, fontWeight: FontWeight.w600, color: KrezioColors.emeraldGreen)),
          ] else if (goal.suggestedMonthlyContribution != null) ...[
            const SizedBox(height: KrezioSpace.sm),
            Text(
              '💡 Guarde ${Money.brl(goal.suggestedMonthlyContribution!)}/mês para chegar a tempo.',
              style: TextStyle(fontSize: KrezioFont.caption, color: secondaryTextColor),
            ),
          ],
        ],
      ),
    );
  }

  void _showContributeDialog(BuildContext context, FinancialGoal goal) {
    final controller = TextEditingController();
    showKrezioFormDialog(
      context,
      title: 'Guardar no Cofrinho: ${goal.title}',
      confirmLabel: 'Aplicar',
      fields: [
        KrezioMoneyField(controller: controller, label: 'Valor para guardar (sai do saldo como despesa)', autofocus: true),
      ],
      onConfirm: () {
        final val = KrezioMoneyField.parse(controller.text);
        if (val == null) return false;
        repository.contributeToGoal(goal.id, val, recordExpense: true);
        return true;
      },
    );
  }

  void _showWithdrawDialog(BuildContext context, FinancialGoal goal) {
    final controller = TextEditingController();
    showKrezioFormDialog(
      context,
      title: 'Resgatar do Cofrinho: ${goal.title}',
      confirmLabel: 'Resgatar',
      fields: [
        KrezioMoneyField(controller: controller, label: 'Valor para devolver ao saldo', autofocus: true),
      ],
      onConfirm: () {
        final val = KrezioMoneyField.parse(controller.text);
        if (val == null) return false;
        repository.withdrawFromGoal(goal.id, val, recordIncome: true);
        return true;
      },
    );
  }

  void _showAddGoalDialog(BuildContext context) {
    final titleController = TextEditingController();
    final amountController = TextEditingController();
    final initialDepositController = TextEditingController();
    showKrezioFormDialog(
      context,
      title: 'Novo Cofrinho',
      confirmLabel: 'Criar Cofrinho',
      fields: [
        KrezioTextField(controller: titleController, label: 'Nome do Cofrinho (ex: Viagem, Reserva)', autofocus: true),
        KrezioMoneyField(controller: amountController, label: 'Meta do Cofrinho (R\$)'),
        KrezioMoneyField(controller: initialDepositController, label: 'Aplicação inicial opcional (sai do saldo)'),
      ],
      onConfirm: () {
        final title = titleController.text.trim();
        final amount = KrezioMoneyField.parse(amountController.text);
        final initialDeposit = KrezioMoneyField.parse(initialDepositController.text) ?? 0.0;
        if (title.isEmpty || amount == null) return false;
        repository.addGoal(
          FinancialGoal(
            id: 'goal-${DateTime.now().millisecondsSinceEpoch}',
            title: title,
            targetAmount: amount,
            savedAmount: initialDeposit,
            isCompleted: initialDeposit >= amount,
          ),
          recordExpense: initialDeposit > 0,
        );
        return true;
      },
    );
  }
}
