import 'package:flutter/material.dart';
import '../../../../core/theme/krezio_theme.dart';
import '../../../../core/repositories/financial_repository.dart';
import '../../../../core/models/financial_transaction.dart';
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
            final matchesTitle = tx.title.toLowerCase().contains(q);
            final matchesCat = tx.categoryLabel.toLowerCase().contains(q);
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
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: primaryTextColor),
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
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (val) => setState(() => _searchQuery = val.trim()),
                  decoration: InputDecoration(
                    hintText: 'Buscar por nome, categoria ou banco...',
                    hintStyle: TextStyle(fontSize: 13, color: secondaryTextColor),
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    border: OutlineInputBorder(borderRadius: KrezioTheme.borderRadius, borderSide: BorderSide.none),
                  ),
                ),
              ),

              // Filter Chips Carousel
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Row(
                  children: [
                    _buildFilterChip('all', 'Todos (${allTxs.length})'),
                    const SizedBox(width: 8),
                    _buildFilterChip('expense', '💸 Despesas'),
                    const SizedBox(width: 8),
                    _buildFilterChip('income', '✨ Receitas'),
                    const SizedBox(width: 8),
                    _buildFilterChip('installments', '💳 Parceladas'),
                    const SizedBox(width: 8),
                    _buildFilterChip('recurrent', '🔁 Recorrentes'),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // Transactions List View
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.search_off, size: 48, color: secondaryTextColor.withOpacity(0.5)),
                            const SizedBox(height: 12),
                            Text(
                              'Nenhum lançamento encontrado.',
                              style: TextStyle(color: secondaryTextColor, fontSize: 14),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final tx = filtered[index];
                          return TransactionListTile(
                            transaction: tx,
                            isDark: widget.isDark,
                            onDelete: () => widget.repository.deleteTransaction(tx.id),
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
      label: Text(label, style: const TextStyle(fontSize: 12)),
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
      ),
    );
  }
}
