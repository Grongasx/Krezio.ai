import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../ai/cesar_text.dart';
import '../../../../../backend/models/financial_reminder.dart';
import '../../../../../backend/repositories/financial_repository.dart';

/// Open bills and people who owe the user, ordered by due date; overdue ones
/// in red. Tapping one registers the payment.
class OpenItemsScreen extends StatelessWidget {
  final FinancialRepository repository;
  final bool isDark;

  const OpenItemsScreen({super.key, required this.repository, required this.isDark});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Contas e devedores'),
          bottom: const TabBar(tabs: [Tab(text: 'Contas em aberto'), Tab(text: 'Quem me deve')]),
        ),
        body: AnimatedBuilder(
          animation: repository,
          builder: (context, _) {
            final debtors = repository.getActiveDebtors()..sort((a, b) => a.targetDate.compareTo(b.targetDate));
            return TabBarView(
              children: [
                _list(
                  context,
                  repository.openBills,
                  empty: const KrezioEmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: 'Nenhuma conta em aberto',
                    message: 'Diga ao César: "me lembra da luz de 180 dia 10"',
                  ),
                  onTap: (r) => _payBill(context, r),
                ),
                _list(
                  context,
                  debtors,
                  empty: const KrezioEmptyState(
                    icon: Icons.handshake_outlined,
                    title: 'Ninguém te deve',
                    message: 'Diga ao César: "emprestei 100 pro João, ele paga dia 30"',
                  ),
                  onTap: (r) => _receiveDebt(context, r),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _list(BuildContext context, List<FinancialReminder> items,
      {required Widget empty, required void Function(FinancialReminder) onTap}) {
    if (items.isEmpty) return empty;
    final now = DateTime.now();
    final secondary = isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;
    final total = items.fold<double>(0, (s, r) => s + (r.amount ?? 0));
    return ListView(
      padding: const EdgeInsets.all(KrezioSpace.lg),
      children: [
        Text('${items.length} em aberto • ${CesarText.money(total)}', style: TextStyle(fontSize: KrezioFont.small, color: secondary)),
        const SizedBox(height: KrezioSpace.sm),
        for (final r in items)
          Padding(
            padding: const EdgeInsets.only(bottom: KrezioSpace.sm),
            child: KrezioCard(
              onTap: () => onTap(r),
              padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
              child: _row(r, now, secondary),
            ),
          ),
      ],
    );
  }

  Widget _row(FinancialReminder r, DateTime now, Color secondary) {
    final overdue = FinancialRepository.isOverdue(r, now);
    final days = DateTime(r.targetDate.year, r.targetDate.month, r.targetDate.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final when = overdue
        ? 'Atrasada há ${-days} ${days == -1 ? 'dia' : 'dias'}'
        : days == 0
            ? 'Vence hoje'
            : days == 1
                ? 'Vence amanhã'
                : 'Vence em ${CesarText.ddmm(r.targetDate)}';
    final color = overdue ? KrezioColors.budgetOver : (days <= 1 ? KrezioColors.budgetWarning : secondary);
    return Row(
      children: [
        Icon(r.icon, color: overdue ? KrezioColors.budgetOver : r.color, size: 20),
        const SizedBox(width: KrezioSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r.personName ?? r.title, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(when, style: TextStyle(fontSize: KrezioFont.small, color: color, fontWeight: overdue ? FontWeight.bold : null)),
            ],
          ),
        ),
        if (r.amount != null) Text(CesarText.money(r.amount!), style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
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
    final controller = TextEditingController(text: r.amount?.toStringAsFixed(2).replaceAll('.', ','));
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Quanto ${r.personName ?? r.title} pagou?'),
        content: KrezioMoneyField(controller: controller, label: 'Valor recebido', autofocus: true),
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
