import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../ai/cesar_text.dart';
import '../../../../../backend/models/financial_reminder.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/services/money.dart';

/// Open bills and people who owe the user, ordered by due date; overdue ones
/// in red. Tapping one registers the payment.
class OpenItemsScreen extends StatelessWidget {
  final FinancialRepository repository;
  final bool isDark;
  final String? focusId;
  final bool showDebtsFirst;

  const OpenItemsScreen({
    super.key,
    required this.repository,
    required this.isDark,
    this.focusId,
    this.showDebtsFirst = false,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: showDebtsFirst ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Lembretes e Contas a Receber'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Contas em aberto'),
              Tab(text: 'Quem me deve'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _showAddReminderDialog(context),
          backgroundColor: KrezioColors.aiPurple,
          icon: const Icon(Icons.add_alert_outlined, color: Colors.white),
          label: const Text('Novo lembrete', style: TextStyle(color: Colors.white)),
        ),
        body: AnimatedBuilder(
          animation: repository,
          builder: (context, _) {
            final allPayables = repository.reminders
                .where((r) =>
                    r.type == ReminderType.billPayment ||
                    r.type == ReminderType.general)
                .toList()
              ..sort((a, b) => a.targetDate.compareTo(b.targetDate));

            final allReceivables = repository.reminders
                .where((r) =>
                    r.type == ReminderType.loanReceivable ||
                    r.type == ReminderType.dividend)
                .toList()
              ..sort((a, b) => a.targetDate.compareTo(b.targetDate));

            return TabBarView(
              children: [
                _list(
                  context,
                  allPayables,
                  isReceivableTab: false,
                  empty: const KrezioEmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: 'Nenhuma conta em aberto',
                    message: 'Diga ao César: "me lembra da luz de 180 dia 10"',
                  ),
                  onTap: (r) => r.isCompleted
                      ? repository.toggleReminderCompleted(r.id)
                      : _payBill(context, r),
                ),
                _list(
                  context,
                  allReceivables,
                  isReceivableTab: true,
                  empty: const KrezioEmptyState(
                    icon: Icons.handshake_outlined,
                    title: 'Ninguém te deve',
                    message: 'Diga ao César: "emprestei 100 pro João, ele paga dia 30"',
                  ),
                  onTap: (r) => r.isCompleted
                      ? repository.toggleReminderCompleted(r.id)
                      : _receiveDebt(context, r),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _list(
    BuildContext context,
    List<FinancialReminder> items, {
    required bool isReceivableTab,
    required Widget empty,
    required void Function(FinancialReminder) onTap,
  }) {
    if (items.isEmpty) return empty;
    final now = DateTime.now();
    final secondary = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;
    final openItems = [
      ...items.where((r) => !r.isCompleted && r.id == focusId),
      ...items.where((r) => !r.isCompleted && r.id != focusId),
    ];
    final completedItems = items.where((r) => r.isCompleted).toList();
    final totalOpen = openItems.fold<double>(0, (s, r) => s + (r.amount ?? 0));
    final prefix = isReceivableTab ? '+ ' : '- ';
    final totalColor = isReceivableTab ? KrezioColors.emeraldGreen : KrezioColors.budgetOver;

    return ListView(
      padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, KrezioSpace.lg, KrezioSpace.lg, 96),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${openItems.length} em aberto',
              style: TextStyle(fontSize: KrezioFont.small, color: secondary),
            ),
            Text(
              '$prefix${CesarText.money(totalOpen)}',
              style: TextStyle(
                fontSize: KrezioFont.bodySmall,
                fontWeight: FontWeight.bold,
                color: totalColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: KrezioSpace.sm),
        if (openItems.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: KrezioSpace.md),
            child: Text(
              'Todos os itens desta aba estão concluídos.',
              style: TextStyle(fontSize: KrezioFont.small, color: secondary),
            ),
          ),
        for (final r in openItems)
          Padding(
            padding: const EdgeInsets.only(bottom: KrezioSpace.sm),
            child: KrezioCard(
              onTap: () => onTap(r),
              padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
              child: _row(r, now, secondary),
            ),
          ),
        if (completedItems.isNotEmpty) ...[
          const SizedBox(height: KrezioSpace.md),
          Text(
            'Concluídos (${completedItems.length})',
            style: TextStyle(
              fontSize: KrezioFont.small,
              fontWeight: FontWeight.bold,
              color: secondary,
            ),
          ),
          const SizedBox(height: KrezioSpace.sm),
          for (final r in completedItems)
            Padding(
              padding: const EdgeInsets.only(bottom: KrezioSpace.sm),
              child: KrezioCard(
                onTap: () => repository.toggleReminderCompleted(r.id),
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
                child: _row(r, now, secondary),
              ),
            ),
        ],
      ],
    );
  }

  Widget _row(FinancialReminder r, DateTime now, Color secondary) {
    final overdue = !r.isCompleted && FinancialRepository.isOverdue(r, now);
    final days = DateTime(r.targetDate.year, r.targetDate.month, r.targetDate.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final when = r.isCompleted
        ? 'Concluído (${CesarText.ddmm(r.targetDate)})'
        : overdue
            ? 'Atrasada há ${-days} ${days == -1 ? 'dia' : 'dias'}'
            : days == 0
                ? 'Vence hoje'
                : days == 1
                    ? 'Vence amanhã'
                    : 'Vence em ${CesarText.ddmm(r.targetDate)}';
    final statusColor = r.isCompleted
        ? secondary
        : overdue
            ? KrezioColors.budgetOver
            : (days <= 1 ? KrezioColors.budgetWarning : secondary);
    return Row(
      children: [
        InkWell(
          onTap: () => repository.toggleReminderCompleted(r.id),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: Icon(
              r.isCompleted ? Icons.check_circle : Icons.radio_button_unchecked,
              color: r.isCompleted ? KrezioColors.emeraldGreen : r.amountColor,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: KrezioSpace.sm),
        Icon(r.icon, color: r.isCompleted ? secondary : r.amountColor, size: 20),
        const SizedBox(width: KrezioSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.personName ?? r.title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  decoration: r.isCompleted ? TextDecoration.lineThrough : null,
                  color: r.isCompleted ? secondary : null,
                ),
              ),
              Text(
                when,
                style: TextStyle(
                  fontSize: KrezioFont.small,
                  color: statusColor,
                  fontWeight: overdue ? FontWeight.bold : null,
                ),
              ),
            ],
          ),
        ),
        if (r.amount != null)
          Text(
            '${r.amountPrefix}${CesarText.money(r.amount!)}',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: r.isCompleted ? secondary : r.amountColor,
              decoration: r.isCompleted ? TextDecoration.lineThrough : null,
            ),
          ),
      ],
    );
  }

  Future<void> _showAddReminderDialog(BuildContext context) async {
    final titleCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    var isReceivable = showDebtsFirst;
    var targetDate = DateTime.now().add(const Duration(days: 7));

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        void submit() {
          final title = titleCtrl.text.trim();
          if (title.isEmpty) return;
          final amount = KrezioMoneyField.parse(amountCtrl.text);
          repository.addReminder(
            FinancialReminder(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              title: title,
              personName: isReceivable ? title : null,
              amount: amount,
              targetDate: targetDate,
              type: isReceivable ? ReminderType.loanReceivable : ReminderType.billPayment,
            ),
          );
          Navigator.pop(ctx);
        }

        return StatefulBuilder(
          builder: (ctx, setModalState) => AlertDialog(
            title: const Text('Novo Lembrete'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: ChoiceChip(
                          label: const Text('A Pagar (-)'),
                          selected: !isReceivable,
                          selectedColor: KrezioColors.budgetOver.withOpacity(0.2),
                          onSelected: (_) => setModalState(() => isReceivable = false),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ChoiceChip(
                          label: const Text('A Receber (+)'),
                          selected: isReceivable,
                          selectedColor: KrezioColors.emeraldGreen.withOpacity(0.2),
                          onSelected: (_) => setModalState(() => isReceivable = true),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: titleCtrl,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => submit(),
                    decoration: InputDecoration(
                      labelText: isReceivable ? 'Quem vai te pagar / Descrição' : 'Descrição da conta',
                    ),
                  ),
                  const SizedBox(height: 12),
                  KrezioMoneyField(
                    controller: amountCtrl,
                    label: 'Valor (R\$)',
                    onSubmitted: (_) => submit(),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_today_outlined),
                    title: Text('Data: ${CesarText.ddmm(targetDate)}/${targetDate.year}'),
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: targetDate,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setModalState(() => targetDate = picked);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
              FilledButton(
                onPressed: submit,
                child: const Text('Salvar'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _payBill(BuildContext context, FinancialReminder r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pagar ${r.title}?'),
        content: Text(r.amount != null && r.amount! > 0
            ? 'Vou registrar uma despesa de ${CesarText.money(r.amount!)} hoje e fechar a conta.'
            : 'Vou marcar a conta como paga.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Marcar como paga')),
        ],
      ),
    );
    if (ok != true) return;
    repository.payBill(r.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r.title} paga. ✅')));
    }
  }

  Future<void> _receiveDebt(BuildContext context, FinancialReminder r) async {
    final controller = TextEditingController(text: r.amount == null ? '' : Money.decimal(r.amount!));
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Quanto ${r.personName ?? r.title} pagou?'),
        content: KrezioMoneyField(
          controller: controller,
          label: 'Valor recebido',
          autofocus: true,
          onSubmitted: (_) => Navigator.pop(ctx, KrezioMoneyField.parse(controller.text)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, KrezioMoneyField.parse(controller.text)),
            child: const Text('Registrar'),
          ),
        ],
      ),
    );
    if (value == null || value <= 0) return;
    final result = repository.applyDebtPayment(r.id, value);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.isFullyPaid
            ? 'Dívida quitada! 🎉'
            : 'Recebido ${CesarText.money(value)}. Falta ${CesarText.money(result.remainingBalance)}.'),
      ));
    }
  }
}
