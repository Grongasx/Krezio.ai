import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/models/budget_category.dart';
import '../../../../../backend/models/financial_goal.dart';

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
  int _tabIndex = 0;

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
              'Metas & Orçamentos',
              style: TextStyle(fontSize: KrezioFont.title, fontWeight: FontWeight.bold, color: primaryTextColor),
            ),
          ),
          floatingActionButton: FloatingActionButton(
            backgroundColor: KrezioColors.aiPurple,
            onPressed: () => _tabIndex == 1 ? _showAddGoalDialog(context) : _showAddCategoryDialog(context),
            child: const Icon(Icons.add, color: Colors.white),
          ),
          body: Column(
            children: [
              _buildTabSelector(),
              Expanded(
                child: _tabIndex == 0 ? _buildBudgetsTab() : _buildGoalsTab(context),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTabSelector() {
    final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final secondaryTextColor = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

    return Padding(
      padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, KrezioSpace.sm, KrezioSpace.lg, KrezioSpace.xs),
      child: Container(
        padding: const EdgeInsets.all(KrezioSpace.xs),
        decoration: BoxDecoration(
          color: bgSurface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(child: _tabButton('Orçamentos', 0, secondaryTextColor)),
            Expanded(child: _tabButton('Metas de Economia', 1, secondaryTextColor)),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(String label, int index, Color unselectedColor) {
    final selected = _tabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _tabIndex = index),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: KrezioSpace.md),
        decoration: BoxDecoration(
          color: selected ? KrezioColors.aiPurple : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: KrezioFont.small,
            fontWeight: FontWeight.bold,
            color: selected ? Colors.white : unselectedColor,
          ),
        ),
      ),
    );
  }

  // ── ORÇAMENTOS ──

  Widget _buildBudgetsTab() {
    final budgets = repository.budgets;
    final totalBudget = budgets.fold(0.0, (acc, b) => acc + b.monthlyLimit);
    final totalSpent = budgets.fold(0.0, (acc, b) => acc + b.currentSpent);
    final overallProgress = totalBudget > 0 ? (totalSpent / totalBudget).clamp(0.0, 1.0) : 0.0;

    final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
    final primaryTextColor = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryTextColor = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

    return ListView(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      children: [
        // Overall Monthly Budget Hero Card
        KrezioCard(
          padding: const EdgeInsets.all(KrezioSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Teto de Gastos Mensal',
                    style: TextStyle(fontSize: KrezioFont.bodySmall, fontWeight: FontWeight.w600, color: secondaryTextColor),
                  ),
                  Text(
                    '${(overallProgress * 100).toStringAsFixed(0)}% Utilizado',
                    style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: KrezioColors.aiPurple),
                  ),
                ],
              ),
              const SizedBox(height: KrezioSpace.md),
              Row(
                children: [
                  Text(
                    'R\$ ${totalSpent.toStringAsFixed(2).replaceAll('.', ',')}',
                    style: TextStyle(fontSize: KrezioFont.headline, fontWeight: FontWeight.bold, color: primaryTextColor),
                  ),
                  Text(
                    ' / R\$ ${totalBudget.toStringAsFixed(2).replaceAll('.', ',')}',
                    style: TextStyle(fontSize: KrezioFont.body, color: secondaryTextColor),
                  ),
                ],
              ),
              const SizedBox(height: KrezioSpace.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: overallProgress,
                  minHeight: 10,
                  backgroundColor: isDark ? KrezioColors.darkBackground : const Color(0xFFE5E7EB),
                  valueColor: AlwaysStoppedAnimation<Color>(_levelColor(
                    overallProgress >= 1 ? BudgetLevel.over : (overallProgress >= 0.8 ? BudgetLevel.warning : BudgetLevel.ok),
                  )),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: KrezioSpace.xl),

        Text(
          'Limites por Categoria',
          style: TextStyle(fontSize: KrezioFont.bodyLarge, fontWeight: FontWeight.bold, color: primaryTextColor),
        ),
        const SizedBox(height: KrezioSpace.md),

        ...budgets.map((b) => _buildBudgetCard(context, b, bgSurface, borderColor, primaryTextColor, secondaryTextColor)),
      ],
    );
  }

  Widget _buildBudgetCard(
    BuildContext context,
    BudgetCategory b,
    Color bgSurface,
    Color borderColor,
    Color primaryTextColor,
    Color secondaryTextColor,
  ) {
    final progress = b.percentage.clamp(0.0, 1.0);
    final statusColor = _levelColor(b.level);

    return Padding(
      padding: const EdgeInsets.only(bottom: KrezioSpace.md),
      child: KrezioCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(KrezioSpace.sm),
                decoration: BoxDecoration(
                  color: b.color.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(b.icon, color: b.color, size: 16),
              ),
              const SizedBox(width: KrezioSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.name,
                      style: TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold, color: primaryTextColor),
                    ),
                    Text(
                      'R\$ ${b.currentSpent.toStringAsFixed(2).replaceAll('.', ',')} de R\$ ${b.monthlyLimit.toStringAsFixed(2).replaceAll('.', ',')}',
                      style: TextStyle(fontSize: KrezioFont.caption, color: secondaryTextColor),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 16),
                color: secondaryTextColor,
                onPressed: () => _showEditBudgetDialog(context, b),
              ),
              if (b.isCustom)
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16),
                  color: secondaryTextColor,
                  tooltip: 'Remover categoria',
                  onPressed: () => _confirmRemoveCategory(context, b),
                ),
            ],
          ),
          const SizedBox(height: KrezioSpace.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: isDark ? KrezioColors.darkBackground : const Color(0xFFE5E7EB),
              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
            ),
          ),
          const SizedBox(height: KrezioSpace.sm),
          Row(
            children: [
              Text(
                b.statusText,
                style: TextStyle(fontSize: KrezioFont.caption, fontWeight: FontWeight.w600, color: b.level == BudgetLevel.ok ? secondaryTextColor : statusColor),
              ),
              const Spacer(),
              Text(
                '${(b.monthlyLimit > 0 ? b.currentSpent / b.monthlyLimit * 100 : 0).toStringAsFixed(0)}%',
                style: TextStyle(fontSize: KrezioFont.caption, color: secondaryTextColor),
              ),
            ],
          ),
        ],
      ),
    ),
    );
  }

  static Color _levelColor(BudgetLevel level) => switch (level) {
        BudgetLevel.ok => KrezioColors.budgetOk,
        BudgetLevel.warning => KrezioColors.budgetWarning,
        BudgetLevel.over => KrezioColors.budgetOver,
      };

  /// Removing a category asks where its transactions go, so none is left
  /// without a category.
  Future<void> _confirmRemoveCategory(BuildContext context, BudgetCategory b) async {
    final count = repository.transactions.where((t) => t.category == b.category).length;
    if (count == 0) {
      repository.removeBudgetCategory(b.category);
      return;
    }
    final targets = repository.budgets.where((x) => x.category != b.category).toList();
    final moveTo = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Apagar ${b.name}?'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(KrezioSpace.xxl, 0, KrezioSpace.xxl, KrezioSpace.sm),
            child: Text('$count ${count == 1 ? 'lançamento está' : 'lançamentos estão'} nesta categoria. Mover para:'),
          ),
          for (final t in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, t.category),
              child: Row(children: [Icon(t.icon, size: 18, color: t.color), const SizedBox(width: KrezioSpace.sm), Text(t.name)]),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'expense_other'),
            child: const Row(children: [Icon(Icons.more_horiz, size: 18), SizedBox(width: KrezioSpace.sm), Text('Outras despesas')]),
          ),
          SimpleDialogOption(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        ],
      ),
    );
    if (moveTo == null) return;
    repository.removeBudgetCategory(b.category, moveTo: moveTo);
  }

  void _showEditBudgetDialog(BuildContext context, BudgetCategory b) {
    final controller = TextEditingController(text: b.monthlyLimit.toStringAsFixed(0));
    final nameController = TextEditingController(text: b.name);
    showKrezioFormDialog(
      context,
      title: b.isCustom ? 'Editar Categoria' : 'Ajustar Meta: ${b.name}',
      fields: [
        // Only custom categories can be renamed — built-in names are
        // referenced by fixed labels elsewhere (transaction list, reports).
        if (b.isCustom)
          KrezioTextField(
            controller: nameController,
            label: 'Nome da categoria',
            textCapitalization: TextCapitalization.sentences,
          ),
        KrezioMoneyField(controller: controller, label: 'Novo Limite Mensal'),
      ],
      onConfirm: () {
        final val = KrezioMoneyField.parse(controller.text);
        if (val == null) return false;
        final newName = nameController.text.trim();
        if (b.isCustom && newName != b.name && !repository.renameBudgetCategory(b.category, newName)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(newName.isEmpty
                  ? 'O nome da categoria não pode ficar vazio.'
                  : 'Já existe uma categoria chamada "$newName".'),
            ),
          );
          return false;
        }
        repository.setBudgetLimit(b.category, val);
        return true;
      },
    );
  }

  // ── METAS DE ECONOMIA ──

  Widget _buildGoalsTab(BuildContext context) {
    final goals = repository.goals;
    final primaryTextColor = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryTextColor = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

    if (goals.isEmpty) {
      return const KrezioEmptyState(
        icon: Icons.flag_outlined,
        title: 'Nenhuma meta ainda',
        message: 'Toque no + ou diga ao César algo como\n"quero juntar 5000 para uma viagem até dezembro"',
      );
    }

    final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;

    return ListView.builder(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      itemCount: goals.length,
      itemBuilder: (context, index) {
        final goal = goals[index];
        return _buildGoalCard(context, goal, goal.colorFor(index), bgSurface, borderColor, primaryTextColor, secondaryTextColor);
      },
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
                child: Icon(goal.isCompleted ? Icons.check_circle : Icons.flag_outlined, color: color, size: 16),
              ),
              const SizedBox(width: KrezioSpace.md),
              Expanded(
                child: Text(
                  goal.title,
                  style: TextStyle(fontSize: KrezioFont.body, fontWeight: FontWeight.bold, color: primaryTextColor),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 20),
                color: KrezioColors.aiPurple,
                tooltip: 'Adicionar valor',
                onPressed: () => _showContributeDialog(context, goal),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                color: secondaryTextColor,
                onPressed: () => repository.deleteGoal(goal.id),
              ),
            ],
          ),
          const SizedBox(height: KrezioSpace.md),
          Text(
            'R\$ ${goal.savedAmount.toStringAsFixed(2).replaceAll('.', ',')} de R\$ ${goal.targetAmount.toStringAsFixed(2).replaceAll('.', ',')}',
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
            const Text('🎉 Meta concluída!', style: TextStyle(fontSize: KrezioFont.caption, fontWeight: FontWeight.w600, color: KrezioColors.emeraldGreen)),
          ] else if (goal.suggestedMonthlyContribution != null) ...[
            const SizedBox(height: KrezioSpace.sm),
            Text(
              '💡 Guarde R\$ ${goal.suggestedMonthlyContribution!.toStringAsFixed(2).replaceAll('.', ',')}/mês para chegar a tempo.',
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
      title: 'Guardar para: ${goal.title}',
      confirmLabel: 'Guardar',
      fields: [KrezioMoneyField(controller: controller, label: 'Valor guardado', autofocus: true)],
      onConfirm: () {
        final val = KrezioMoneyField.parse(controller.text);
        if (val == null) return false;
        repository.contributeToGoal(goal.id, val);
        return true;
      },
    );
  }

  void _showAddCategoryDialog(BuildContext context) {
    final nameController = TextEditingController();
    final limitController = TextEditingController();
    showKrezioFormDialog(
      context,
      title: 'Nova Categoria',
      confirmLabel: 'Criar',
      fields: [
        KrezioTextField(controller: nameController, label: 'Nome (ex: Pets, Presentes)', autofocus: true),
        KrezioMoneyField(controller: limitController, label: 'Limite mensal'),
      ],
      onConfirm: () {
        final name = nameController.text.trim();
        final limit = KrezioMoneyField.parse(limitController.text);
        if (name.isEmpty || limit == null) return false;
        final existing = repository.existingCategoryNamed(name);
        if (existing != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Essa categoria já existe: ${existing.name}')),
          );
          return false;
        }
        repository.addBudgetCategory(name, limit);
        return true;
      },
    );
  }

  void _showAddGoalDialog(BuildContext context) {
    final titleController = TextEditingController();
    final amountController = TextEditingController();
    showKrezioFormDialog(
      context,
      title: 'Nova Meta de Economia',
      confirmLabel: 'Criar',
      fields: [
        KrezioTextField(controller: titleController, label: 'Título (ex: Viagem, Notebook)', autofocus: true),
        KrezioMoneyField(controller: amountController, label: 'Valor alvo'),
      ],
      onConfirm: () {
        final title = titleController.text.trim();
        final amount = KrezioMoneyField.parse(amountController.text);
        if (title.isEmpty || amount == null) return false;
        repository.addGoal(FinancialGoal(
          id: 'goal-${DateTime.now().millisecondsSinceEpoch}',
          title: title,
          targetAmount: amount,
        ));
        return true;
      },
    );
  }
}
