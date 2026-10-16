import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../ai/cesar_text.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/models/financial_transaction.dart';
import '../../../../../backend/services/statement_query.dart';
import '../widgets/transaction_list_tile.dart';
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
                  isLabelVisible: _filter.category != null || _filter.paymentMethod != null,
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

              // Period
              _chipRow([
                _chip('Tudo', _filter.period == StatementPeriod.all, () => _setPeriod(StatementPeriod.all)),
                _chip('Este mês', _filter.period == StatementPeriod.thisMonth, () => _setPeriod(StatementPeriod.thisMonth)),
                _chip('Mês passado', _filter.period == StatementPeriod.lastMonth, () => _setPeriod(StatementPeriod.lastMonth)),
                _chip(
                  _filter.period == StatementPeriod.custom && _filter.from != null
                      ? '${CesarText.ddmm(_filter.from!)} – ${CesarText.ddmm(_filter.to!)}'
                      : 'Personalizado',
                  _filter.period == StatementPeriod.custom,
                  () => _pickRange(context),
                ),
              ]),
              // Type and kind
              _chipRow([
                _chip('Despesas', _filter.type == TransactionType.expense, () => _toggleType(TransactionType.expense)),
                _chip('Receitas', _filter.type == TransactionType.income, () => _toggleType(TransactionType.income)),
                _chip('Parceladas', _filter.onlyInstallments,
                    () => setState(() => _filter = _filter.copyWith(onlyInstallments: !_filter.onlyInstallments))),
                _chip('Recorrentes', _filter.onlyRecurrent,
                    () => setState(() => _filter = _filter.copyWith(onlyRecurrent: !_filter.onlyRecurrent))),
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
                    ? KrezioEmptyState(
                        icon: _filter.isEmpty ? Icons.receipt_long_outlined : Icons.search_off,
                        title: _filter.isEmpty ? 'Nenhum lançamento ainda' : 'Nenhum lançamento encontrado',
                        message: _filter.isEmpty
                            ? 'Fale com o César: "gastei 50 no mercado no pix"'
                            : 'Tente outra palavra ou limpe os filtros.',
                      )
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
          onDelete: () => widget.repository.deleteTransaction(tx.id),
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
    final categories = {for (final t in widget.repository.transactions) t.category}.toList()
      ..sort((a, b) => _categoryName(a).compareTo(_categoryName(b)));
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(KrezioSpace.lg, 0, KrezioSpace.lg, KrezioSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Categoria', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: KrezioSpace.sm),
              Wrap(spacing: KrezioSpace.sm, runSpacing: KrezioSpace.sm, children: [
                for (final c in categories)
                  _chip(_categoryName(c), _filter.category == c, () {
                    setState(() => _filter =
                        _filter.category == c ? _filter.copyWith(clearCategory: true) : _filter.copyWith(category: c));
                    Navigator.pop(ctx);
                  }),
              ]),
              const SizedBox(height: KrezioSpace.lg),
              const Text('Forma de pagamento', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: KrezioSpace.sm),
              Wrap(spacing: KrezioSpace.sm, runSpacing: KrezioSpace.sm, children: [
                for (final p in _payments.entries)
                  _chip(p.value, _filter.paymentMethod == p.key, () {
                    setState(() => _filter = _filter.paymentMethod == p.key
                        ? _filter.copyWith(clearPayment: true)
                        : _filter.copyWith(paymentMethod: p.key));
                    Navigator.pop(ctx);
                  }),
              ]),
            ],
          ),
        ),
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
