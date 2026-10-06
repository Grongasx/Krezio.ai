import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
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
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: primaryTextColor),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.all(4),
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
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? KrezioColors.aiPurple : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
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
      padding: const EdgeInsets.all(16),
      children: [
        // Overall Monthly Budget Hero Card
        Container(
          padding: const EdgeInsets.all(18),
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
                    'Teto de Gastos Mensal',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: secondaryTextColor),
                  ),
                  Text(
                    '${(overallProgress * 100).toStringAsFixed(0)}% Utilizado',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: KrezioColors.aiPurple),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    'R\$ ${totalSpent.toStringAsFixed(2).replaceAll('.', ',')}',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: primaryTextColor),
                  ),
                  Text(
                    ' / R\$ ${totalBudget.toStringAsFixed(2).replaceAll('.', ',')}',
                    style: TextStyle(fontSize: 14, color: secondaryTextColor),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: overallProgress,
                  minHeight: 10,
                  backgroundColor: isDark ? KrezioColors.darkBackground : const Color(0xFFE5E7EB),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    overallProgress >= 0.9 ? KrezioColors.friendlyOrange : KrezioColors.aiPurple,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        Text(
          'Limites por Categoria',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: primaryTextColor),
        ),
        const SizedBox(height: 12),

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
    final statusColor = b.isOverBudget
        ? KrezioColors.friendlyOrange
        : (b.isNearLimit ? KrezioColors.friendlyOrange : b.color);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: b.color.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(b.icon, color: b.color, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      b.name,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: primaryTextColor),
                    ),
                    Text(
                      'R\$ ${b.currentSpent.toStringAsFixed(2).replaceAll('.', ',')} de R\$ ${b.monthlyLimit.toStringAsFixed(2).replaceAll('.', ',')}',
                      style: TextStyle(fontSize: 11, color: secondaryTextColor),
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
                  onPressed: () => repository.removeBudgetCategory(b.category),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: isDark ? KrezioColors.darkBackground : const Color(0xFFE5E7EB),
              valueColor: AlwaysStoppedAnimation<Color>(statusColor),
            ),
          ),
          if (b.isOverBudget) ...[
            const SizedBox(height: 8),
            Text(
              '⚠️ Limite mensal ultrapassado em R\$ ${(b.currentSpent - b.monthlyLimit).toStringAsFixed(2).replaceAll('.', ',')}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: KrezioColors.friendlyOrange),
            ),
          ] else if (b.isNearLimit) ...[
            const SizedBox(height: 8),
            Text(
              '💡 Restam R\$ ${b.remaining.toStringAsFixed(2).replaceAll('.', ',')} para atingir o teto.',
              style: TextStyle(fontSize: 11, color: secondaryTextColor),
            ),
          ],
        ],
      ),
    );
  }

  void _showEditBudgetDialog(BuildContext context, BudgetCategory b) {
    final controller = TextEditingController(text: b.monthlyLimit.toStringAsFixed(0));
    final nameController = TextEditingController(text: b.name);
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: KrezioTheme.borderRadius),
          title: Text(b.isCustom ? 'Editar Categoria' : 'Ajustar Meta: ${b.name}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Only custom categories can be renamed — built-in names are
              // referenced by fixed labels elsewhere (transaction list, reports).
              if (b.isCustom) ...[
                TextField(
                  controller: nameController,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Nome da categoria'),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Novo Limite Mensal (R\$)',
                  prefixText: 'R\$ ',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: KrezioColors.aiPurple),
              onPressed: () {
                final val = double.tryParse(controller.text);
                if (val == null || val <= 0) return;
                final newName = nameController.text.trim();
                if (b.isCustom && newName != b.name && !repository.renameBudgetCategory(b.category, newName)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(newName.isEmpty
                          ? 'O nome da categoria não pode ficar vazio.'
                          : 'Já existe uma categoria chamada "$newName".'),
                    ),
                  );
                  return;
                }
                repository.setBudgetLimit(b.category, val);
                Navigator.of(ctx).pop();
              },
              child: const Text('Salvar', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  // ── METAS DE ECONOMIA ──

  Widget _buildGoalsTab(BuildContext context) {
    final goals = repository.goals;
    final primaryTextColor = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryTextColor = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

    if (goals.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.flag_outlined, size: 48, color: secondaryTextColor),
              const SizedBox(height: 16),
              Text(
                'Nenhuma meta ainda',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: primaryTextColor),
              ),
              const SizedBox(height: 8),
              Text(
                'Toque no + ou diga ao César algo como\n"quero juntar 5000 para uma viagem até dezembro"',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: secondaryTextColor),
              ),
            ],
          ),
        ),
      );
    }

    final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;

    return ListView.builder(
      padding: const EdgeInsets.all(16),
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
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
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
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: color.withOpacity(0.12), shape: BoxShape.circle),
                child: Icon(goal.isCompleted ? Icons.check_circle : Icons.flag_outlined, color: color, size: 16),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  goal.title,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: primaryTextColor),
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
          const SizedBox(height: 10),
          Text(
            'R\$ ${goal.savedAmount.toStringAsFixed(2).replaceAll('.', ',')} de R\$ ${goal.targetAmount.toStringAsFixed(2).replaceAll('.', ',')}',
            style: TextStyle(fontSize: 12, color: secondaryTextColor),
          ),
          const SizedBox(height: 8),
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
            const SizedBox(height: 8),
            const Text('🎉 Meta concluída!', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: KrezioColors.emeraldGreen)),
          ] else if (goal.suggestedMonthlyContribution != null) ...[
            const SizedBox(height: 8),
            Text(
              '💡 Guarde R\$ ${goal.suggestedMonthlyContribution!.toStringAsFixed(2).replaceAll('.', ',')}/mês para chegar a tempo.',
              style: TextStyle(fontSize: 11, color: secondaryTextColor),
            ),
          ],
        ],
      ),
    );
  }

  void _showContributeDialog(BuildContext context, FinancialGoal goal) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: KrezioTheme.borderRadius),
          title: Text('Guardar para: ${goal.title}'),
          content: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Valor guardado', prefixText: 'R\$ '),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: KrezioColors.aiPurple),
              onPressed: () {
                final val = double.tryParse(controller.text.replaceAll(',', '.'));
                if (val != null && val > 0) {
                  repository.contributeToGoal(goal.id, val);
                  Navigator.of(ctx).pop();
                }
              },
              child: const Text('Guardar', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showAddCategoryDialog(BuildContext context) {
    final nameController = TextEditingController();
    final limitController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: KrezioTheme.borderRadius),
          title: const Text('Nova Categoria'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nome (ex: Pets, Presentes)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: limitController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Limite mensal', prefixText: 'R\$ '),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: KrezioColors.aiPurple),
              onPressed: () {
                final name = nameController.text.trim();
                final limit = double.tryParse(limitController.text.replaceAll(',', '.'));
                if (name.isNotEmpty && limit != null && limit > 0) {
                  repository.addBudgetCategory(name, limit);
                  Navigator.of(ctx).pop();
                }
              },
              child: const Text('Criar', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showAddGoalDialog(BuildContext context) {
    final titleController = TextEditingController();
    final amountController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: KrezioTheme.borderRadius),
          title: const Text('Nova Meta de Economia'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Título (ex: Viagem, Notebook)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Valor alvo', prefixText: 'R\$ '),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancelar')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: KrezioColors.aiPurple),
              onPressed: () {
                final title = titleController.text.trim();
                final amount = double.tryParse(amountController.text.replaceAll(',', '.'));
                if (title.isNotEmpty && amount != null && amount > 0) {
                  repository.addGoal(FinancialGoal(
                    id: 'goal-${DateTime.now().millisecondsSinceEpoch}',
                    title: title,
                    targetAmount: amount,
                  ));
                  Navigator.of(ctx).pop();
                }
              },
              child: const Text('Criar', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }
}
