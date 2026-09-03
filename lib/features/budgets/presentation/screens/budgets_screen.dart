import 'package:flutter/material.dart';
import '../../../../core/theme/krezio_theme.dart';
import '../../../../core/repositories/financial_repository.dart';
import '../../../../core/models/budget_category.dart';

class BudgetsScreen extends StatelessWidget {
  final FinancialRepository repository;
  final bool isDark;

  const BudgetsScreen({
    super.key,
    required this.repository,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: repository,
      builder: (context, _) {
        final budgets = repository.budgets;
        final totalBudget = budgets.fold(0.0, (acc, b) => acc + b.monthlyLimit);
        final totalSpent = budgets.fold(0.0, (acc, b) => acc + b.currentSpent);
        final overallProgress = totalBudget > 0 ? (totalSpent / totalBudget).clamp(0.0, 1.0) : 0.0;

        final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
        final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
        final primaryTextColor = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
        final secondaryTextColor = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: isDark ? KrezioColors.darkBackground : KrezioColors.lightBackground,
            elevation: 0,
            title: Text(
              'Metas & Orçamentos',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: primaryTextColor),
            ),
          ),
          body: ListView(
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
          ),
        );
      },
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
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: KrezioTheme.borderRadius),
          title: Text('Ajustar Meta: ${b.name}'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Novo Limite Mensal (R\$)',
              prefixText: 'R\$ ',
            ),
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
                if (val != null && val > 0) {
                  repository.setBudgetLimit(b.category, val);
                  Navigator.of(ctx).pop();
                }
              },
              child: const Text('Salvar', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }
}
