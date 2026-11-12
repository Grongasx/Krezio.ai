import 'package:flutter/material.dart';
import '../../../../../ai/chat_action_history.dart';
import '../../../../../backend/models/budget_category.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/services/money.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../widgets/ledger_undo.dart';

/// Status filter of the budgets list.
enum BudgetStatusFilter { all, ok, warning, over }

/// Sort order of the budgets list.
enum BudgetSort { usage, name, limit }

/// Orçamentos (monthly limits per category). Lives inside the Lançamentos
/// tab, separate from the Cofrinhos.
class BudgetsView extends StatefulWidget {
  final FinancialRepository repository;
  final bool isDark;
  final String? focusedCategory;

  const BudgetsView({
    super.key,
    required this.repository,
    required this.isDark,
    this.focusedCategory,
  });

  /// "Nova Categoria" dialog, also used by the Lançamentos app bar.
  static void showAddCategoryDialog(BuildContext context, FinancialRepository repository) {
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

  @override
  State<BudgetsView> createState() => _BudgetsViewState();
}

class _BudgetsViewState extends State<BudgetsView> {
  BudgetStatusFilter _status = BudgetStatusFilter.all;
  BudgetSort _sort = BudgetSort.usage;

  FinancialRepository get repository => widget.repository;
  bool get isDark => widget.isDark;

  static Color _levelColor(BudgetLevel level) => switch (level) {
        BudgetLevel.ok => KrezioColors.budgetOk,
        BudgetLevel.warning => KrezioColors.budgetWarning,
        BudgetLevel.over => KrezioColors.budgetOver,
      };

  bool _matches(BudgetCategory b) => switch (_status) {
        BudgetStatusFilter.all => true,
        BudgetStatusFilter.ok => b.level == BudgetLevel.ok,
        BudgetStatusFilter.warning => b.level == BudgetLevel.warning,
        BudgetStatusFilter.over => b.level == BudgetLevel.over,
      };

  List<BudgetCategory> _visibleBudgets() {
    final list = repository.budgets.where(_matches).toList();
    switch (_sort) {
      case BudgetSort.usage:
        list.sort((a, b) => b.percentage.compareTo(a.percentage));
        break;
      case BudgetSort.name:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case BudgetSort.limit:
        list.sort((a, b) => b.monthlyLimit.compareTo(a.monthlyLimit));
        break;
    }
    // The category the user came from (dashboard) always shows first.
    final focus = widget.focusedCategory;
    if (focus != null) {
      final i = list.indexWhere((b) => b.category == focus);
      if (i > 0) list.insert(0, list.removeAt(i));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final all = repository.budgets;
    final budgets = _visibleBudgets();
    final totalBudget = all.fold(0.0, (acc, b) => acc + b.monthlyLimit);
    final totalSpent = all.fold(0.0, (acc, b) => acc + b.currentSpent);
    final overallProgress = totalBudget > 0 ? (totalSpent / totalBudget).clamp(0.0, 1.0) : 0.0;

    final primaryTextColor = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryTextColor = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

    int count(BudgetLevel l) => all.where((b) => b.level == l).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, KrezioSpace.sm, KrezioSpace.lg, 96),
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
                  Expanded(
                    child: Text(
                      'Teto de Gastos Mensal',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: KrezioFont.bodySmall, fontWeight: FontWeight.w600, color: secondaryTextColor),
                    ),
                  ),
                  const SizedBox(width: KrezioSpace.sm),
                  Text(
                    '${(overallProgress * 100).toStringAsFixed(0)}% Utilizado',
                    style: const TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: KrezioColors.aiPurple),
                  ),
                ],
              ),
              const SizedBox(height: KrezioSpace.md),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  Text(
                    Money.brl(totalSpent),
                    style: TextStyle(fontSize: KrezioFont.headline, fontWeight: FontWeight.bold, color: primaryTextColor),
                  ),
                  Text(
                    ' / ${Money.brl(totalBudget)}',
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
        const SizedBox(height: KrezioSpace.lg),

        // Filters: status as an even grid of 4 tiles with counts + sort.
        Row(
          children: [
            Expanded(
              child: Text(
                'Limites por Categoria',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: KrezioFont.bodyLarge, fontWeight: FontWeight.bold, color: primaryTextColor),
              ),
            ),
            const SizedBox(width: KrezioSpace.sm),
            PopupMenuButton<BudgetSort>(
              tooltip: 'Ordenar',
              initialValue: _sort,
              onSelected: (s) => setState(() => _sort = s),
              itemBuilder: (_) => const [
                PopupMenuItem(value: BudgetSort.usage, child: Text('Mais usados primeiro')),
                PopupMenuItem(value: BudgetSort.name, child: Text('Nome (A–Z)')),
                PopupMenuItem(value: BudgetSort.limit, child: Text('Maior limite')),
              ],
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sort, size: 18, color: secondaryTextColor),
                  const SizedBox(width: 4),
                  Text(
                    switch (_sort) {
                      BudgetSort.usage => 'Uso',
                      BudgetSort.name => 'Nome',
                      BudgetSort.limit => 'Limite',
                    },
                    style: TextStyle(fontSize: KrezioFont.small, color: secondaryTextColor),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: KrezioSpace.sm),
        Row(
          children: [
            _statusTile(BudgetStatusFilter.all, 'Todos', all.length, KrezioColors.aiPurple),
            const SizedBox(width: KrezioSpace.xs),
            _statusTile(BudgetStatusFilter.ok, 'No controle', count(BudgetLevel.ok), KrezioColors.budgetOk),
            const SizedBox(width: KrezioSpace.xs),
            _statusTile(BudgetStatusFilter.warning, 'Atenção', count(BudgetLevel.warning), KrezioColors.budgetWarning),
            const SizedBox(width: KrezioSpace.xs),
            _statusTile(BudgetStatusFilter.over, 'Estourados', count(BudgetLevel.over), KrezioColors.budgetOver),
          ],
        ),
        const SizedBox(height: KrezioSpace.md),

        if (budgets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: KrezioSpace.xl),
            child: Text(
              'Nenhuma categoria neste filtro.',
              textAlign: TextAlign.center,
              style: TextStyle(color: secondaryTextColor),
            ),
          ),
        ...budgets.map((b) => _buildBudgetCard(context, b, primaryTextColor, secondaryTextColor)),
      ],
    );
  }

  Widget _statusTile(BudgetStatusFilter value, String label, int count, Color color) {
    final selected = _status == value;
    final border = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _status = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: KrezioSpace.sm, horizontal: 2),
          decoration: BoxDecoration(
            color: selected ? color.withOpacity(0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? color : border, width: selected ? 1.5 : 1),
          ),
          child: Column(
            children: [
              Text(
                '$count',
                style: TextStyle(fontSize: KrezioFont.bodyLarge, fontWeight: FontWeight.bold, color: color),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: KrezioFont.caption,
                  fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBudgetCard(
    BuildContext context,
    BudgetCategory b,
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
                        '${Money.brl(b.currentSpent)} de ${Money.brl(b.monthlyLimit)}',
                        style: TextStyle(fontSize: KrezioFont.caption, color: secondaryTextColor),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  color: secondaryTextColor,
                  tooltip: 'Editar limite',
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
                Expanded(
                  child: Text(
                    b.statusText,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: KrezioFont.caption,
                      fontWeight: FontWeight.w600,
                      color: b.level == BudgetLevel.ok ? secondaryTextColor : statusColor,
                    ),
                  ),
                ),
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

  /// Removing a category asks where its transactions go, so none is left
  /// without a category.
  Future<void> _confirmRemoveCategory(BuildContext context, BudgetCategory b) async {
    final count = repository.transactions.where((t) => t.category == b.category).length;
    if (count == 0) {
      _removeCategory(context, b);
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
    if (moveTo == null || !context.mounted) return;
    _removeCategory(context, b, moveTo: moveTo);
  }

  void _removeCategory(BuildContext context, BudgetCategory budget, {String? moveTo}) {
    final undo = repository.deleteBudgetCategoryWithUndo(budget.category, moveTo: moveTo);
    if (undo == null) return;
    showLedgerUndo(context, repository, ChatAction.restoration((_) => undo(), 'Categoria restaurada.'), 'Categoria apagada.');
  }

  void _showEditBudgetDialog(BuildContext context, BudgetCategory b) {
    final controller = TextEditingController(text: Money.groupedDecimal(b.monthlyLimit));
    final nameController = TextEditingController(text: b.name);
    showKrezioFormDialog(
      context,
      title: b.isCustom ? 'Editar Categoria' : 'Ajustar Limite: ${b.name}',
      fields: [
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
}

