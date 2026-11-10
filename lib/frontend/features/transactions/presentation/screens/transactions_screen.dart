import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../ai/cesar_text.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/models/budget_category.dart';
import '../../../../../backend/models/financial_transaction.dart';
import '../../../../../backend/services/money.dart';
import '../../../../../backend/services/statement_query.dart';
import '../widgets/transaction_list_tile.dart';
import '../../../../widgets/ledger_undo.dart';
import '../widgets/add_transaction_modal.dart';

class TransactionsScreen extends StatefulWidget {
  final FinancialRepository repository;
  final bool isDark;

  const TransactionsScreen({
    super.key,
    required this.repository,
    required this.isDark,
  });

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  StatementFilter _filter = const StatementFilter();
  final _searchController = TextEditingController();

  static const _payments = {
    'pix': 'Pix',
    'credit_card': 'Crédito',
    'debit_card': 'Débito',
    'cash': 'Dinheiro',
    'bank_slip': 'Boleto',
  };

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _categoryName(String code) => CesarText.categoryName(code, widget.repository.budgets);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.repository,
      builder: (context, _) {
        final now = DateTime.now();
        final filtered = StatementQuery.apply(widget.repository.transactions, _filter, now: now, categoryName: _categoryName);
        final days = StatementQuery.groupByDay(filtered);

        final bgSurface = widget.isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
        final primaryTextColor = widget.isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
        final secondaryTextColor = widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

        return Scaffold(
          appBar: AppBar(
            backgroundColor: widget.isDark ? KrezioColors.darkBackground : KrezioColors.lightBackground,
            elevation: 0,
            title: Text(
              'Extrato de Transações',
              style: TextStyle(fontSize: KrezioFont.title, fontWeight: FontWeight.bold, color: primaryTextColor),
            ),
            actions: [
              IconButton(
                tooltip: 'Mais filtros',
                icon: Badge(
                  isLabelVisible: _filter.category != null ||
                      _filter.paymentMethod != null ||
                      _filter.minAmount != null ||
                      _filter.maxAmount != null,
                  child: Icon(Icons.tune, color: primaryTextColor),
                ),
                onPressed: () => _openFilterSheet(context),
              ),
              IconButton(
                icon: const Icon(Icons.add, color: KrezioColors.aiPurple),
                onPressed: () => _openAddModal(context),
              ),
            ],
          ),
          body: Column(
            children: [
              // Search: ignores accents and case ("acougue" finds "Açougue").
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.sm),
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => _filter = _filter.copyWith(text: val)),
                  decoration: InputDecoration(
                    hintText: 'Buscar por nome, categoria ou banco...',
                    hintStyle: TextStyle(fontSize: KrezioFont.bodySmall, color: secondaryTextColor),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _filter.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _filter = _filter.copyWith(text: ''));
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: bgSurface,
                    contentPadding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
                    border: OutlineInputBorder(borderRadius: KrezioTheme.borderRadius, borderSide: BorderSide.none),
                  ),
                ),
              ),

              // Organic Filter Bar: Period Popups, Value Range Popup, Category/Payment Popups & Quick Chips
              _chipRow([
                _filterPopupChip(
                  icon: Icons.calendar_today_outlined,
                  label: _periodLabel(),
                  active: _filter.period != StatementPeriod.all,
                  onTap: () => _openPeriodPopup(context),
                ),
                _filterPopupChip(
                  icon: Icons.attach_money,
                  label: _amountRangeLabel(),
                  active: _filter.minAmount != null || _filter.maxAmount != null,
                  onTap: () => _openAmountRangeDialog(context),
                ),
                _filterPopupChip(
                  icon: Icons.category_outlined,
                  label: _filter.category != null ? _categoryName(_filter.category!) : 'Categorias',
                  active: _filter.category != null,
                  onTap: () => _openFilterSheet(context),
                ),
                _chip('Despesas', _filter.type == TransactionType.expense, () => _toggleType(TransactionType.expense)),
                _chip('Receitas', _filter.type == TransactionType.income, () => _toggleType(TransactionType.income)),
                _chip('Parceladas', _filter.onlyInstallments,
                    () => setState(() => _filter = _filter.copyWith(onlyInstallments: !_filter.onlyInstallments))),
                _chip('Recorrentes', _filter.onlyRecurrent,
                    () => setState(() => _filter = _filter.copyWith(onlyRecurrent: !_filter.onlyRecurrent))),
              ]),

              // Active Removable Filter Pills
              if (_filter.category != null ||
                  _filter.paymentMethod != null ||
                  _filter.minAmount != null ||
                  _filter.maxAmount != null)
                _chipRow([
                  if (_filter.minAmount != null || _filter.maxAmount != null)
                    _chip('${_amountRangeLabel()} ✕', true, () {
                      setState(() => _filter = _filter.copyWith(clearMinAmount: true, clearMaxAmount: true));
                    }),
                  if (_filter.category != null)
                    _chip('${_categoryName(_filter.category!)} ✕', true,
                        () => setState(() => _filter = _filter.copyWith(clearCategory: true))),
                  if (_filter.paymentMethod != null)
                    _chip('${_payments[_filter.paymentMethod] ?? _filter.paymentMethod} ✕', true,
                        () => setState(() => _filter = _filter.copyWith(clearPayment: true))),
                ]),

              // Filtered total
              if (!_filter.isEmpty && filtered.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, KrezioSpace.xs, KrezioSpace.lg, 0),
                  child: Row(
                    children: [
                      Text('${filtered.length} lançamento${filtered.length == 1 ? '' : 's'}',
                          style: TextStyle(fontSize: KrezioFont.small, color: secondaryTextColor)),
                      const SizedBox(width: KrezioSpace.sm),
                      Expanded(
                        child: Text('Total: ${_signedMoney(StatementQuery.net(filtered))}',
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: primaryTextColor)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: KrezioSpace.sm),

              // Statement grouped by day. The builder only builds what is on
              // screen, so a thousand records scroll without lag.
              Expanded(
                child: !widget.repository.isLoaded
                    ? const KrezioSkeletonList()
                        : filtered.isEmpty
                        ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                          KrezioEmptyState(
                        icon: _filter.isEmpty ? Icons.receipt_long_outlined : Icons.search_off,
                        title: _filter.isEmpty ? 'Nenhum lançamento ainda' : 'Nenhum lançamento encontrado',
                        message: _filter.isEmpty
                            ? 'Fale com o César: "gastei 50 no mercado no pix"'
                            : 'Tente outra palavra ou limpe os filtros.',
                          ),
                          if (!_filter.isEmpty)
                            TextButton(
                              onPressed: _clearFilters,
                              child: const Text('Limpar filtros'),
                            ),
                        ]))
                    : _buildGroupedList(days, now, secondaryTextColor),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildGroupedList(List<StatementDay> days, DateTime now, Color secondaryTextColor) {
    // Flattened rows: a header (StatementDay) followed by its transactions.
    final rows = <Object>[];
    for (final d in days) {
      rows.add(d);
      rows.addAll(d.transactions);
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.sm),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        if (row is StatementDay) {
          return Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : KrezioSpace.md, bottom: KrezioSpace.sm),
            child: Row(
              children: [
                Text(StatementQuery.dayHeader(row.day, now),
                    style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: secondaryTextColor)),
                const Spacer(),
                Text(_signedMoney(row.total), style: TextStyle(fontSize: KrezioFont.small, color: secondaryTextColor)),
              ],
            ),
          );
        }
        final tx = row as FinancialTransaction;
        return TransactionListTile(
          key: ValueKey(tx.id),
          transaction: tx,
          isDark: widget.isDark,
          onDelete: () => deleteLedgerTransaction(context, widget.repository, tx.id),
          onTap: () => _openEditModal(context, tx),
        );
      },
    );
  }

  String _signedMoney(double v) => v > 0 ? '+${CesarText.money(v)}' : CesarText.money(v);

  Widget _chipRow(List<Widget> chips) => Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.xs),
          child: Row(children: [for (final c in chips) Padding(padding: const EdgeInsets.only(right: KrezioSpace.sm), child: c)]),
        ),
      );

  Widget _chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: KrezioFont.small)),
        selected: selected,
        selectedColor: KrezioColors.aiPurple,
        onSelected: (_) => onTap(),
      );

  Widget _filterPopupChip({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final borderColor = widget.isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: active ? KrezioColors.aiPurple.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? KrezioColors.aiPurple : borderColor,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: active ? KrezioColors.aiPurple : null),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: KrezioFont.small,
                fontWeight: active ? FontWeight.bold : FontWeight.w500,
                color: active ? KrezioColors.aiPurple : null,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down,
              size: 16,
              color: active ? KrezioColors.aiPurple : null,
            ),
          ],
        ),
      ),
    );
  }

  String _periodLabel() {
    switch (_filter.period) {
      case StatementPeriod.all:
        return 'Período: Tudo';
      case StatementPeriod.thisMonth:
        return 'Este mês';
      case StatementPeriod.lastMonth:
        return 'Mês passado';
      case StatementPeriod.custom:
        if (_filter.from != null && _filter.to != null) {
          return '${CesarText.ddmm(_filter.from!)} – ${CesarText.ddmm(_filter.to!)}';
        }
        return 'Personalizado';
    }
  }

  String _amountRangeLabel() {
    final min = _filter.minAmount;
    final max = _filter.maxAmount;
    if (min != null && max != null) {
      return '${Money.brl(min)} – ${Money.brl(max)}';
    }
    if (min != null) return 'Acima de ${Money.brl(min)}';
    if (max != null) return 'Até ${Money.brl(max)}';
    return 'Margem de Valor';
  }

  void _openPeriodPopup(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, 0, KrezioSpace.lg, KrezioSpace.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Filtrar por Período', style: TextStyle(fontSize: KrezioFont.bodyLarge, fontWeight: FontWeight.bold)),
              const SizedBox(height: KrezioSpace.md),
              ListTile(
                leading: const Icon(Icons.all_inclusive),
                title: const Text('Todo o histórico'),
                trailing: _filter.period == StatementPeriod.all ? const Icon(Icons.check, color: KrezioColors.aiPurple) : null,
                onTap: () {
                  _setPeriod(StatementPeriod.all);
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.today),
                title: const Text('Este mês'),
                trailing: _filter.period == StatementPeriod.thisMonth ? const Icon(Icons.check, color: KrezioColors.aiPurple) : null,
                onTap: () {
                  _setPeriod(StatementPeriod.thisMonth);
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Mês passado'),
                trailing: _filter.period == StatementPeriod.lastMonth ? const Icon(Icons.check, color: KrezioColors.aiPurple) : null,
                onTap: () {
                  _setPeriod(StatementPeriod.lastMonth);
                  Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.date_range),
                title: const Text('Escolher datas (Personalizado)'),
                trailing: _filter.period == StatementPeriod.custom ? const Icon(Icons.check, color: KrezioColors.aiPurple) : null,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickRange(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openAmountRangeDialog(BuildContext context) {
    final minCtrl = TextEditingController(
      text: _filter.minAmount != null ? Money.groupedDecimal(_filter.minAmount!) : '',
    );
    final maxCtrl = TextEditingController(
      text: _filter.maxAmount != null ? Money.groupedDecimal(_filter.maxAmount!) : '',
    );

    showDialog<void>(
      context: context,
      builder: (ctx) {
        void apply() {
          final minVal = KrezioMoneyField.parse(minCtrl.text);
          final maxVal = KrezioMoneyField.parse(maxCtrl.text);
          setState(() {
            _filter = _filter.copyWith(
              minAmount: minVal,
              maxAmount: maxVal,
              clearMinAmount: minVal == null,
              clearMaxAmount: maxVal == null,
            );
          });
          Navigator.pop(ctx);
        }

        return AlertDialog(
          title: const Text('Margem de Valor (Gasto / Recebido)'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Defina o intervalo de valor para filtrar os lançamentos:',
                  style: TextStyle(fontSize: KrezioFont.small),
                ),
                const SizedBox(height: KrezioSpace.md),
                KrezioMoneyField(
                  controller: minCtrl,
                  label: 'Valor mínimo (R\$)',
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => apply(),
                ),
                const SizedBox(height: KrezioSpace.md),
                KrezioMoneyField(
                  controller: maxCtrl,
                  label: 'Valor máximo (R\$)',
                  onSubmitted: (_) => apply(),
                ),
                const SizedBox(height: KrezioSpace.md),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ActionChip(
                      label: const Text('Até R\$ 50', style: TextStyle(fontSize: KrezioFont.caption)),
                      onPressed: () {
                        minCtrl.clear();
                        maxCtrl.text = '50,00';
                      },
                    ),
                    ActionChip(
                      label: const Text('R\$ 50 – R\$ 200', style: TextStyle(fontSize: KrezioFont.caption)),
                      onPressed: () {
                        minCtrl.text = '50,00';
                        maxCtrl.text = '200,00';
                      },
                    ),
                    ActionChip(
                      label: const Text('R\$ 200 – R\$ 1.000', style: TextStyle(fontSize: KrezioFont.caption)),
                      onPressed: () {
                        minCtrl.text = '200,00';
                        maxCtrl.text = '1.000,00';
                      },
                    ),
                    ActionChip(
                      label: const Text('Acima de R\$ 1.000', style: TextStyle(fontSize: KrezioFont.caption)),
                      onPressed: () {
                        minCtrl.text = '1.000,00';
                        maxCtrl.clear();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() => _filter = _filter.copyWith(clearMinAmount: true, clearMaxAmount: true));
                Navigator.pop(ctx);
              },
              child: const Text('Limpar margem'),
            ),
            FilledButton(
              onPressed: apply,
              child: const Text('Aplicar'),
            ),
          ],
        );
      },
    );
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() => _filter = const StatementFilter());
  }

  void _setPeriod(StatementPeriod p) => setState(() => _filter = _filter.copyWith(period: p));

  void _toggleType(TransactionType t) => setState(
      () => _filter = _filter.type == t ? _filter.copyWith(clearType: true) : _filter.copyWith(type: t));

  Future<void> _pickRange(BuildContext context) async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _filter.from != null && _filter.to != null
          ? DateTimeRange(start: _filter.from!, end: _filter.to!)
          : DateTimeRange(start: DateTime(now.year, now.month), end: now),
    );
    if (range == null) return;
    setState(() => _filter = _filter.copyWith(period: StatementPeriod.custom, from: range.start, to: range.end));
  }

  void _openFilterSheet(BuildContext context) {
    final categories = {
      for (final b in widget.repository.budgets) b.category,
      for (final t in widget.repository.transactions) t.category,
    }.toList()
      ..sort((a, b) => _categoryName(a).compareTo(_categoryName(b)));

    final minCtrl = TextEditingController(
      text: _filter.minAmount != null ? Money.groupedDecimal(_filter.minAmount!) : '',
    );
    final maxCtrl = TextEditingController(
      text: _filter.maxAmount != null ? Money.groupedDecimal(_filter.maxAmount!) : '',
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final secondary = widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;
          void apply() {
            final minVal = KrezioMoneyField.parse(minCtrl.text);
            final maxVal = KrezioMoneyField.parse(maxCtrl.text);
            setState(() {
              _filter = _filter.copyWith(
                minAmount: minVal,
                maxAmount: maxVal,
                clearMinAmount: minVal == null,
                clearMaxAmount: maxVal == null,
              );
            });
            Navigator.pop(ctx);
          }

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.84),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  KrezioSpace.lg,
                  0,
                  KrezioSpace.lg,
                  MediaQuery.of(ctx).viewInsets.bottom + KrezioSpace.lg,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Filtros Avançados',
                          style: TextStyle(fontSize: KrezioFont.title, fontWeight: FontWeight.bold),
                        ),
                        TextButton(
                          onPressed: () {
                            minCtrl.clear();
                            maxCtrl.clear();
                            _clearFilters();
                            setModalState(() {});
                          },
                          child: const Text('Limpar tudo'),
                        ),
                      ],
                    ),
                    const SizedBox(height: KrezioSpace.md),

                    // Section 1: Margem de Valor
                    KrezioCard(
                      padding: const EdgeInsets.all(KrezioSpace.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.payments_outlined, size: 18, color: KrezioColors.emeraldGreen),
                              SizedBox(width: 8),
                              Text('Margem de Valor (Gasto / Recebido)', style: TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: KrezioSpace.sm),
                          Row(
                            children: [
                              Expanded(
                                child: KrezioMoneyField(
                                  controller: minCtrl,
                                  label: 'Mínimo',
                                  textInputAction: TextInputAction.next,
                                  onSubmitted: (_) => apply(),
                                ),
                              ),
                              const SizedBox(width: KrezioSpace.sm),
                              Expanded(
                                child: KrezioMoneyField(
                                  controller: maxCtrl,
                                  label: 'Máximo',
                                  onSubmitted: (_) => apply(),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: KrezioSpace.md),

                    // Section 2: Categorias com ícones
                    KrezioCard(
                      padding: const EdgeInsets.all(KrezioSpace.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.category_outlined, size: 18, color: KrezioColors.aiPurple),
                              const SizedBox(width: 8),
                              const Text('Categorias', style: TextStyle(fontWeight: FontWeight.bold)),
                              const Spacer(),
                              if (_filter.category != null)
                                Text(
                                  _categoryName(_filter.category!),
                                  style: TextStyle(fontSize: KrezioFont.caption, color: secondary),
                                ),
                            ],
                          ),
                          const SizedBox(height: KrezioSpace.sm),
                          Wrap(
                            spacing: KrezioSpace.sm,
                            runSpacing: KrezioSpace.sm,
                            children: [
                              for (final c in categories)
                                ChoiceChip(
                                  avatar: Icon(
                                    BudgetCategory.getIconForCategory(c),
                                    size: 14,
                                    color: _filter.category == c ? Colors.white : BudgetCategory.getColorForCategory(c),
                                  ),
                                  label: Text(_categoryName(c), style: const TextStyle(fontSize: KrezioFont.small)),
                                  selected: _filter.category == c,
                                  selectedColor: KrezioColors.aiPurple,
                                  onSelected: (_) {
                                    setState(() => _filter = _filter.category == c
                                        ? _filter.copyWith(clearCategory: true)
                                        : _filter.copyWith(category: c));
                                    setModalState(() {});
                                  },
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: KrezioSpace.md),

                    // Section 3: Forma de Pagamento
                    KrezioCard(
                      padding: const EdgeInsets.all(KrezioSpace.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.credit_card_outlined, size: 18, color: KrezioColors.friendlyOrange),
                              SizedBox(width: 8),
                              Text('Forma de Pagamento', style: TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: KrezioSpace.sm),
                          Wrap(
                            spacing: KrezioSpace.sm,
                            runSpacing: KrezioSpace.sm,
                            children: [
                              for (final p in _payments.entries)
                                _chip(p.value, _filter.paymentMethod == p.key, () {
                                  setState(() => _filter = _filter.paymentMethod == p.key
                                      ? _filter.copyWith(clearPayment: true)
                                      : _filter.copyWith(paymentMethod: p.key));
                                  setModalState(() {});
                                }),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: KrezioSpace.lg),

                    KrezioButton(
                      label: 'Aplicar Filtros',
                      expand: true,
                      onPressed: apply,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openAddModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddTransactionModal(
        isDark: widget.isDark,
        onAdd: (tx) => widget.repository.addTransaction(tx),
        customCategories: widget.repository.budgets.where((b) => b.isCustom).toList(),
        accounts: widget.repository.activeAccounts,
      ),
    );
  }

  void _openEditModal(BuildContext context, FinancialTransaction tx) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddTransactionModal(
        isDark: widget.isDark,
        initialTransaction: tx,
        onAdd: (updated) => widget.repository.updateTransaction(updated),
        customCategories: widget.repository.budgets.where((b) => b.isCustom).toList(),
        accounts: widget.repository.activeAccounts,
      ),
    );
  }
}
