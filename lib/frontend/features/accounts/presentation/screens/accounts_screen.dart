import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../ai/cesar_text.dart';
import '../../../../../backend/models/financial_account.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/services/credit_card_invoice.dart';

/// Accounts and wallets: balance of each one, create, rename, archive,
/// transfer between them, and the credit card invoice.
class AccountsScreen extends StatefulWidget {
  final FinancialRepository repository;
  final bool isDark;

  const AccountsScreen({super.key, required this.repository, required this.isDark});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  bool _showArchived = false;

  FinancialRepository get repo => widget.repository;

  @override
  Widget build(BuildContext context) {
    final secondary = widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Contas e carteiras'),
        actions: [
          IconButton(
            tooltip: 'Transferir entre contas',
            icon: const Icon(Icons.swap_horiz),
            onPressed: () => _transfer(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(context),
        backgroundColor: KrezioColors.aiPurple,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Nova conta', style: TextStyle(color: Colors.white)),
      ),
      body: AnimatedBuilder(
        animation: repo,
        builder: (context, _) {
          final list = repo.accounts.where((a) => _showArchived || !a.archived).toList();
          final archivedCount = repo.accounts.where((a) => a.archived).length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, KrezioSpace.lg, KrezioSpace.lg, 96),
            children: [
              Text('Saldo total', style: TextStyle(fontSize: KrezioFont.small, color: secondary)),
              Text(CesarText.money(repo.totalBalance),
                  style: const TextStyle(fontSize: KrezioFont.headline, fontWeight: FontWeight.bold)),
              const SizedBox(height: KrezioSpace.lg),
              for (final a in list) _accountCard(context, a, secondary),
              if (archivedCount > 0)
                TextButton(
                  onPressed: () => setState(() => _showArchived = !_showArchived),
                  child: Text(_showArchived ? 'Esconder arquivadas' : 'Mostrar arquivadas ($archivedCount)'),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _accountCard(BuildContext context, FinancialAccount a, Color secondary) {
    final now = DateTime.now();
    String subtitle = a.kindLabel;
    if (a.isCreditCard) {
      final due = CreditCardInvoice.dueFor(now, closingDay: a.closingDay!, dueDay: a.dueDay!);
      final total = CreditCardInvoice.total(repo.transactions, a, due);
      subtitle = 'Fatura aberta: ${CesarText.money(total)} • vence ${CesarText.ddmm(due)}';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: KrezioSpace.sm),
      child: KrezioCard(
        onTap: a.isCreditCard ? () => _showInvoice(context, a) : null,
        padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
        child: Row(
          children: [
            Icon(_iconFor(a.kind), color: a.archived ? secondary : KrezioColors.aiPurple),
            const SizedBox(width: KrezioSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(a.archived ? '${a.name} (arquivada)' : a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(subtitle, style: TextStyle(fontSize: KrezioFont.small, color: secondary)),
                ],
              ),
            ),
            if (!a.isCreditCard)
              Text(CesarText.money(repo.balanceOf(a.id)), style: const TextStyle(fontWeight: FontWeight.bold)),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'rename') _rename(context, a);
                if (v == 'archive') repo.archiveAccount(a.id, archived: !a.archived);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Renomear')),
                if (a.id != FinancialAccount.mainId)
                  PopupMenuItem(value: 'archive', child: Text(a.archived ? 'Desarquivar' : 'Arquivar')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(AccountKind k) => switch (k) {
        AccountKind.checking => Icons.account_balance_outlined,
        AccountKind.savings => Icons.savings_outlined,
        AccountKind.wallet => Icons.account_balance_wallet_outlined,
        AccountKind.creditCard => Icons.credit_card,
      };

  Future<void> _create(BuildContext context) async {
    final name = TextEditingController();
    final closing = TextEditingController();
    final due = TextEditingController();
    var kind = AccountKind.checking;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Nova conta'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                KrezioTextField(controller: name, label: 'Nome', hint: 'Ex.: Nubank, Carteira', errorText: error, autofocus: true),
                const SizedBox(height: KrezioSpace.md),
                Wrap(spacing: KrezioSpace.sm, children: [
                  for (final k in AccountKind.values)
                    ChoiceChip(
                      label: Text(FinancialAccount(id: '', name: '', kind: k).kindLabel),
                      selected: kind == k,
                      onSelected: (_) => setLocal(() => kind = k),
                    ),
                ]),
                if (kind == AccountKind.creditCard) ...[
                  const SizedBox(height: KrezioSpace.md),
                  KrezioTextField(controller: closing, label: 'Dia do fechamento', keyboardType: TextInputType.number),
                  const SizedBox(height: KrezioSpace.sm),
                  KrezioTextField(controller: due, label: 'Dia do vencimento', keyboardType: TextInputType.number),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                int? day(TextEditingController c) {
                  final v = int.tryParse(c.text.trim());
                  return v != null && v >= 1 && v <= 31 ? v : null;
                }

                if (kind == AccountKind.creditCard && (day(closing) == null || day(due) == null)) {
                  setLocal(() => error = 'Informe os dias de fechamento e vencimento (1 a 31).');
                  return;
                }
                final created = repo.addAccount(name.text, kind: kind, closingDay: day(closing), dueDay: day(due));
                if (created == null) {
                  setLocal(() => error = name.text.trim().isEmpty ? 'Dê um nome à conta.' : 'Essa conta já existe.');
                  return;
                }
                Navigator.pop(ctx);
              },
              child: const Text('Criar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, FinancialAccount a) async {
    final name = TextEditingController(text: a.name);
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Renomear conta'),
          content: KrezioTextField(controller: name, label: 'Nome', errorText: error, autofocus: true),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                if (!repo.renameAccount(a.id, name.text)) {
                  setLocal(() => error = 'Nome vazio ou já usado.');
                  return;
                }
                Navigator.pop(ctx);
              },
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _transfer(BuildContext context) async {
    final options = repo.activeAccounts.where((a) => !a.isCreditCard).toList();
    if (options.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Crie mais uma conta para transferir entre elas.')),
      );
      return;
    }
    var from = options[0].id;
    var to = options[1].id;
    final amount = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Transferir entre contas'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: from,
                decoration: const InputDecoration(labelText: 'De'),
                items: [for (final a in options) DropdownMenuItem(value: a.id, child: Text(a.name))],
                onChanged: (v) => setLocal(() => from = v ?? from),
              ),
              DropdownButtonFormField<String>(
                value: to,
                decoration: const InputDecoration(labelText: 'Para'),
                items: [for (final a in options) DropdownMenuItem(value: a.id, child: Text(a.name))],
                onChanged: (v) => setLocal(() => to = v ?? to),
              ),
              const SizedBox(height: KrezioSpace.sm),
              KrezioMoneyField(controller: amount, label: 'Valor', errorText: error),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
            FilledButton(
              onPressed: () {
                final v = KrezioMoneyField.parse(amount.text);
                if (from == to) return setLocal(() => error = 'Escolha duas contas diferentes.');
                if (v == null) return setLocal(() => error = 'Informe um valor válido.');
                repo.transferBetweenAccounts(from: from, to: to, amount: v);
                Navigator.pop(ctx);
              },
              child: const Text('Transferir'),
            ),
          ],
        ),
      ),
    );
  }

  void _showInvoice(BuildContext context, FinancialAccount card) {
    var due = CreditCardInvoice.dueFor(DateTime.now(), closingDay: card.closingDay!, dueDay: card.dueDay!);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final items = CreditCardInvoice.items(repo.transactions, card, due);
          final total = items.fold<double>(0, (s, i) => s + i.amount);
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.6,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        onPressed: () => setLocal(() => due = DateTime(due.year, due.month - 1, 1)),
                      ),
                      Column(children: [
                        Text('Fatura ${card.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
                        Text('Vence ${CesarText.ddmm(CreditCardInvoice.dueDate(card, due))}/${due.year} • ${CesarText.money(total)}'),
                      ]),
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        onPressed: () => setLocal(() => due = DateTime(due.year, due.month + 1, 1)),
                      ),
                    ],
                  ),
                  const Divider(),
                  Expanded(
                    child: items.isEmpty
                        ? const KrezioEmptyState(icon: Icons.credit_card_off, title: 'Nada nesta fatura', compact: true)
                        : ListView(
                            children: [
                              for (final i in items)
                                ListTile(
                                  dense: true,
                                  title: Text(i.transaction.title),
                                  subtitle: Text([CesarText.ddmm(i.transaction.date), i.installmentLabel].where((x) => x.isNotEmpty).join(' • ')),
                                  trailing: Text(CesarText.money(i.amount)),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
