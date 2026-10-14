import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../backend/repositories/financial_repository.dart';
import '../../../../../backend/models/financial_transaction.dart';
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
  String _selectedFilter = 'all'; // all, expense, income, installments, recurrent
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.repository,
      builder: (context, _) {
        final allTxs = widget.repository.transactions;

        // Apply Search & Filter
        final filtered = allTxs.where((tx) {
          if (_searchQuery.isNotEmpty) {
            final q = _searchQuery.toLowerCase();
            final categoryName = widget.repository.budgets
                .cast<dynamic>()
                .firstWhere((b) => b.category == tx.category, orElse: () => null)
                ?.name as String? ??
                tx.categoryLabel;
            final matchesTitle = tx.title.toLowerCase().contains(q);
            final matchesCat = categoryName.toLowerCase().contains(q);
            final matchesBank = tx.bankSource?.toLowerCase().contains(q) ?? false;
            if (!matchesTitle && !matchesCat && !matchesBank) return false;
          }

          if (_selectedFilter == 'expense') return tx.type == TransactionType.expense;
          if (_selectedFilter == 'income') return tx.type == TransactionType.income;
          if (_selectedFilter == 'installments') return tx.installments != null && tx.installments! > 1;
          if (_selectedFilter == 'recurrent') return tx.isRecurrent;
          return true;
        }).toList();

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
                icon: const Icon(Icons.add, color: KrezioColors.aiPurple),
                onPressed: () => _openAddModal(context),
              ),
            ],
          ),
          body: Column(
            children: [
              // Search Bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.sm),
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                  decoration: InputDecoration(
                    hintText: 'Buscar por nome, categoria ou banco...',
                    hintStyle: TextStyle(fontSize: KrezioFont.bodySmall, color: secondaryTextColor),
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 16),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
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

              // Filter Chips Carousel
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.xs),
                child: Row(
                  children: [
                    _buildFilterChip('all', 'Todos (${allTxs.length})'),
                    const SizedBox(width: KrezioSpace.sm),
                    _buildFilterChip('expense', '💸 Despesas'),
                    const SizedBox(width: KrezioSpace.sm),
                    _buildFilterChip('income', '✨ Receitas'),
                    const SizedBox(width: KrezioSpace.sm),
                    _buildFilterChip('installments', '💳 Parceladas'),
                    const SizedBox(width: KrezioSpace.sm),
                    _buildFilterChip('recurrent', '🔁 Recorrentes'),
                  ],
                ),
              ),
              const SizedBox(height: KrezioSpace.sm),

              // Transactions List View
              Expanded(
                child: filtered.isEmpty
                    ? KrezioEmptyState(
                        icon: _searchQuery.isEmpty ? Icons.receipt_long_outlined : Icons.search_off,
                        title: _searchQuery.isEmpty ? 'Nenhum lançamento ainda' : 'Nenhum lançamento encontrado',
                        message: _searchQuery.isEmpty
                            ? 'Fale com o César: "gastei 50 no mercado no pix"'
                            : 'Tente outra palavra ou limpe a busca.',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.sm),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final tx = filtered[index];
                          return TransactionListTile(
                            transaction: tx,
                            isDark: widget.isDark,
                            onDelete: () => widget.repository.deleteTransaction(tx.id),
                            onTap: () => _openEditModal(context, tx),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFilterChip(String key, String label) {
    final isSelected = _selectedFilter == key;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: KrezioFont.small)),
      selected: isSelected,
      selectedColor: KrezioColors.aiPurple,
      onSelected: (val) {
        if (val) setState(() => _selectedFilter = key);
      },
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
      ),
    );
  }
}
