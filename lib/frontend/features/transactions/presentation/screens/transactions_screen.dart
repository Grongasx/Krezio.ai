import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../ai/cesar_text.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/models/budget_category.dart';
import '../../../../../backend/models/financial_transaction.dart';
import '../../../../../backend/services/statement_query.dart';
import '../widgets/transaction_list_tile.dart';
import '../../../../widgets/ledger_undo.dart';
import '../widgets/add_transaction_modal.dart';
import '../../../budgets/presentation/widgets/budgets_view.dart';

class TransactionsScreen extends StatefulWidget {
  final FinancialRepository repository;
  final bool isDark;

  /// Opens directly on the Orçamentos view (from the dashboard).
  final bool showBudgets;

  /// Budget category to highlight first in the Orçamentos view.
  final String? focusedBudget;

  const TransactionsScreen({
    super.key,
    required this.repository,
    required this.isDark,
    this.showBudgets = false,
    this.focusedBudget,
  });

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  StatementFilter _filter = const StatementFilter();
  final _searchController = TextEditingController();
  late bool _showBudgets = widget.showBudgets;

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
              _showBudgets ? 'Orçamentos' : 'Extrato de Transações',
              style: TextStyle(fontSize: KrezioFont.title, fontWeight: FontWeight.bold, color: primaryTextColor),
            ),
            actions: [
              if (_showBudgets)
                IconButton(
                  tooltip: 'Nova categoria',
                  icon: const Icon(Icons.add, color: KrezioColors.aiPurple),
                  onPressed: () => BudgetsView.showAddCategoryDialog(context, widget.repository),
                )
              else ...[
              IconButton(
                tooltip: 'Filtros',
                icon: Badge(
                  isLabelVisible: _hasActiveModalFilters(),
                  child: Icon(Icons.tune, color: primaryTextColor),
                ),
                onPressed: () => _openFilterSheet(context),
              ),
              IconButton(
                tooltip: 'Novo lançamento',
                icon: const Icon(Icons.add, color: KrezioColors.aiPurple),
                onPressed: () => _openAddModal(context),
              ),
              ],
            ],
          ),
          body: Column(
            children: [
              _viewSwitcher(bgSurface, secondaryTextColor),
              if (_showBudgets)
                Expanded(
                  child: BudgetsView(
                    repository: widget.repository,
                    isDark: widget.isDark,
                    focusedCategory: widget.focusedBudget,
                  ),
                )
              else
                Expanded(child: _buildStatement(context, filtered, days, now, bgSurface, primaryTextColor, secondaryTextColor)),
            ],
          ),
        );
      },
    );
  }

  /// "Extrato | Orçamentos" segmented switch at the top of the tab.
  Widget _viewSwitcher(Color bgSurface, Color unselected) {
    Widget seg(String label, IconData icon, bool budgets) {
      final selected = _showBudgets == budgets;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _showBudgets = budgets),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: KrezioSpace.sm),
            decoration: BoxDecoration(
              color: selected ? KrezioColors.aiPurple : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 16, color: selected ? Colors.white : unselected),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: KrezioFont.small,
                    fontWeight: FontWeight.bold,
                    color: selected ? Colors.white : unselected,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, KrezioSpace.xs, KrezioSpace.lg, KrezioSpace.xs),
      child: Container(
        padding: const EdgeInsets.all(KrezioSpace.xs),
        decoration: BoxDecoration(color: bgSurface, borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            seg('Extrato', Icons.receipt_long_outlined, false),
            seg('Orçamentos', Icons.pie_chart_outline, true),
          ],
        ),
      ),
    );
  }

  Widget _buildStatement(
    BuildContext context,
    List<FinancialTransaction> filtered,
    List<StatementDay> days,
    DateTime now,
    Color bgSurface,
    Color primaryTextColor,
    Color secondaryTextColor,
  ) {
    return Column(
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

              // Unified Filter Trigger + Active Filter Pills
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.xs),
                child: Row(
                  children: [
                    _filterPopupChip(
                      icon: Icons.tune,
                      label: _activeFilterCount() > 0 ? 'Filtros (${_activeFilterCount()})' : 'Filtros',
                      active: _hasActiveModalFilters(),
                      onTap: () => _openFilterSheet(context),
                    ),
                    const SizedBox(width: KrezioSpace.sm),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _buildActiveFilterChips(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

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

  Widget _chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: KrezioFont.small)),
        selected: selected,
        selectedColor: KrezioColors.aiPurple,
        onSelected: (_) => onTap(),
      );

  bool _hasActiveModalFilters() =>
      _filter.period != StatementPeriod.all ||
      _filter.type != null ||
      _filter.onlyInstallments ||
      _filter.onlyRecurrent ||
      _filter.category != null ||
      _filter.paymentMethod != null;

  int _activeFilterCount() {
    var count = 0;
    if (_filter.period != StatementPeriod.all) count++;
    if (_filter.type != null) count++;
    if (_filter.onlyInstallments) count++;
    if (_filter.onlyRecurrent) count++;
    if (_filter.category != null) count++;
    if (_filter.paymentMethod != null) count++;
    return count;
  }

  List<Widget> _buildActiveFilterChips() {
    final chips = <Widget>[];
    if (_filter.period != StatementPeriod.all) {
      chips.add(Padding(
        padding: const EdgeInsets.only(right: KrezioSpace.xs),
        child: _chip('${_periodLabel()} ✕', true, () => _setPeriod(StatementPeriod.all)),
      ));
    }
    if (_filter.type == TransactionType.expense) {
      chips.add(Padding(
        padding: const EdgeInsets.only(right: KrezioSpace.xs),
        child: _chip('Despesas ✕', true, () => setState(() => _filter = _filter.copyWith(clearType: true))),
      ));
    } else if (_filter.type == TransactionType.income) {
      chips.add(Padding(
        padding: const EdgeInsets.only(right: KrezioSpace.xs),
        child: _chip('Receitas ✕', true, () => setState(() => _filter = _filter.copyWith(clearType: true))),
      ));
    }
    if (_filter.onlyInstallments) {
      chips.add(Padding(
        padding: const EdgeInsets.only(right: KrezioSpace.xs),
        child: _chip('Parceladas ✕', true, () => setState(() => _filter = _filter.copyWith(onlyInstallments: false))),
      ));
    }
    if (_filter.onlyRecurrent) {
      chips.add(Padding(
        padding: const EdgeInsets.only(right: KrezioSpace.xs),
        child: _chip('Recorrentes ✕', true, () => setState(() => _filter = _filter.copyWith(onlyRecurrent: false))),
      ));
    }
    if (_filter.category != null) {
      chips.add(Padding(
        padding: const EdgeInsets.only(right: KrezioSpace.xs),
        child: _chip('${_categoryName(_filter.category!)} ✕', true, () => setState(() => _filter = _filter.copyWith(clearCategory: true))),
      ));
    }
    if (_filter.paymentMethod != null) {
      chips.add(Padding(
        padding: const EdgeInsets.only(right: KrezioSpace.xs),
        child: _chip('${_payments[_filter.paymentMethod] ?? _filter.paymentMethod} ✕', true, () => setState(() => _filter = _filter.copyWith(clearPayment: true))),
      ));
    }
    return chips;
  }

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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active ? KrezioColors.aiPurple.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? KrezioColors.aiPurple : borderColor,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: active ? KrezioColors.aiPurple : null),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: KrezioFont.caption,
                  fontWeight: active ? FontWeight.bold : FontWeight.w500,
                  color: active ? KrezioColors.aiPurple : null,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.keyboard_arrow_down,
              size: 14,
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
        return 'Todo o histórico';
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

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final secondary = widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.88),
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
                          'Filtros',
                          style: TextStyle(fontSize: KrezioFont.title, fontWeight: FontWeight.bold),
                        ),
                        TextButton(
                          onPressed: () {
                            _clearFilters();
                            setModalState(() {});
                          },
                          child: const Text('Limpar tudo'),
                        ),
                      ],
                    ),
                    const SizedBox(height: KrezioSpace.md),

                    // Section 1: Período / Data
                    KrezioCard(
                      padding: const EdgeInsets.all(KrezioSpace.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.calendar_today_outlined, size: 18, color: KrezioColors.aiPurple),
                              const SizedBox(width: 8),
                              const Text('Período', style: TextStyle(fontWeight: FontWeight.bold)),
                              const Spacer(),
                              if (_filter.period != StatementPeriod.all)
                                Text(
                                  _periodLabel(),
                                  style: TextStyle(fontSize: KrezioFont.caption, color: secondary),
                                ),
                            ],
                          ),
                          const SizedBox(height: KrezioSpace.sm),
                          Wrap(
                            spacing: KrezioSpace.sm,
                            runSpacing: KrezioSpace.sm,
                            children: [
                              ChoiceChip(
                                label: const Text('Este mês', style: TextStyle(fontSize: KrezioFont.small)),
                                selected: _filter.period == StatementPeriod.thisMonth,
                                selectedColor: KrezioColors.aiPurple,
                                onSelected: (_) {
                                  _setPeriod(StatementPeriod.thisMonth);
                                  setModalState(() {});
                                },
                              ),
                              ChoiceChip(
                                label: const Text('Mês passado', style: TextStyle(fontSize: KrezioFont.small)),
                                selected: _filter.period == StatementPeriod.lastMonth,
                                selectedColor: KrezioColors.aiPurple,
                                onSelected: (_) {
                                  _setPeriod(StatementPeriod.lastMonth);
                                  setModalState(() {});
                                },
                              ),
                              ChoiceChip(
                                label: const Text('Todo o histórico', style: TextStyle(fontSize: KrezioFont.small)),
                                selected: _filter.period == StatementPeriod.all,
                                selectedColor: KrezioColors.aiPurple,
                                onSelected: (_) {
                                  _setPeriod(StatementPeriod.all);
                                  setModalState(() {});
                                },
                              ),
                              ChoiceChip(
                                avatar: const Icon(Icons.date_range, size: 14),
                                label: Text(
                                  _filter.period == StatementPeriod.custom ? _periodLabel() : 'Personalizado...',
                                  style: const TextStyle(fontSize: KrezioFont.small),
                                ),
                                selected: _filter.period == StatementPeriod.custom,
                                selectedColor: KrezioColors.aiPurple,
                                onSelected: (_) async {
                                  await _pickRange(context);
                                  setModalState(() {});
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: KrezioSpace.md),

                    // Section 2: Tipo de Lançamento
                    KrezioCard(
                      padding: const EdgeInsets.all(KrezioSpace.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.swap_vert_circle_outlined, size: 18, color: KrezioColors.friendlyOrange),
                              SizedBox(width: 8),
                              Text('Tipo de Lançamento', style: TextStyle(fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: KrezioSpace.sm),
                          Wrap(
                            spacing: KrezioSpace.sm,
                            runSpacing: KrezioSpace.sm,
                            children: [
                              _chip('Despesas', _filter.type == TransactionType.expense, () {
                                _toggleType(TransactionType.expense);
                                setModalState(() {});
                              }),
                              _chip('Receitas', _filter.type == TransactionType.income, () {
                                _toggleType(TransactionType.income);
                                setModalState(() {});
                              }),
                              _chip('Parceladas', _filter.onlyInstallments, () {
                                setState(() => _filter = _filter.copyWith(onlyInstallments: !_filter.onlyInstallments));
                                setModalState(() {});
                              }),
                              _chip('Recorrentes', _filter.onlyRecurrent, () {
                                setState(() => _filter = _filter.copyWith(onlyRecurrent: !_filter.onlyRecurrent));
                                setModalState(() {});
                              }),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: KrezioSpace.md),

                    // Section 3: Categorias com ícones
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

                    // Section 4: Forma de Pagamento
                    KrezioCard(
                      padding: const EdgeInsets.all(KrezioSpace.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.credit_card_outlined, size: 18, color: KrezioColors.emeraldGreen),
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
                      onPressed: () => Navigator.pop(ctx),
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
