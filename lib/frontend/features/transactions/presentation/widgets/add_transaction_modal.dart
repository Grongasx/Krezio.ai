import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../../backend/models/financial_transaction.dart';
import '../../../../../backend/models/budget_category.dart';
import '../../../../../ai/local_nlp_engine.dart';

class AddTransactionModal extends StatefulWidget {
  final bool isDark;
  final Function(FinancialTransaction) onAdd;

  /// When set, the modal edits this transaction instead of creating a new one:
  /// fields start pre-filled and [onAdd] receives the updated copy (same id).
  final FinancialTransaction? initialTransaction;

  /// User-created categories, offered as chips next to the built-in ones.
  final List<BudgetCategory> customCategories;

  const AddTransactionModal({
    super.key,
    required this.isDark,
    required this.onAdd,
    this.initialTransaction,
    this.customCategories = const [],
  });

  @override
  State<AddTransactionModal> createState() => _AddTransactionModalState();
}

class _AddTransactionModalState extends State<AddTransactionModal> {
  final _titleController = TextEditingController();
  final _amountController = TextEditingController();
  TransactionType _selectedType = TransactionType.expense;
  String _selectedCategory = 'supermarket';
  String _selectedPaymentMethod = 'pix';
  int _installments = 1;
  bool _isRecurrent = false;
  int? _dueDay;
  late DateTime _date;

  bool get _isEditing => widget.initialTransaction != null;

  @override
  void initState() {
    super.initState();
    final tx = widget.initialTransaction;
    _date = tx?.date ?? DateTime.now();
    if (tx == null) return;
    _titleController.text = tx.title;
    _amountController.text = tx.amount.toStringAsFixed(2).replaceAll('.', ',');
    _selectedType = tx.type;
    _selectedCategory = tx.category;
    _selectedPaymentMethod = _paymentMethods.any((p) => p['id'] == tx.paymentMethod) ? tx.paymentMethod : 'pix';
    _installments = tx.installments ?? 1;
    _isRecurrent = tx.isRecurrent;
    _dueDay = tx.dueDay;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _allCategories => [
        ..._categories,
        ...widget.customCategories.map((c) => {'id': c.category, 'label': c.name, 'icon': c.icon}),
      ];

  /// Category actually saved. Income keeps whatever income category the
  /// transaction already had (e.g. "income_other" from the chat) when editing,
  /// instead of forcing everything to "salary".
  String get _resolvedCategory {
    if (_selectedType != TransactionType.income) return _selectedCategory;
    final original = widget.initialTransaction;
    if (original != null && original.type == TransactionType.income) return original.category;
    return 'salary';
  }

  final List<Map<String, dynamic>> _categories = [
    {'id': 'supermarket', 'label': 'Supermercado', 'icon': Icons.shopping_cart_outlined},
    {'id': 'transport', 'label': 'Transporte', 'icon': Icons.directions_car_outlined},
    {'id': 'leisure', 'label': 'Lazer/Comida', 'icon': Icons.restaurant_outlined},
    {'id': 'housing', 'label': 'Moradia', 'icon': Icons.home_outlined},
    {'id': 'health', 'label': 'Saúde', 'icon': Icons.local_hospital_outlined},
    {'id': 'education', 'label': 'Educação', 'icon': Icons.school_outlined},
    {'id': 'salary', 'label': 'Salário', 'icon': Icons.work_outline},
    {'id': 'investment', 'label': 'Investimento', 'icon': Icons.trending_up},
  ];

  final List<Map<String, String>> _paymentMethods = [
    {'id': 'pix', 'label': 'Pix'},
    {'id': 'credit_card', 'label': 'Crédito'},
    {'id': 'debit_card', 'label': 'Débito'},
    {'id': 'cash', 'label': 'Dinheiro'},
    {'id': 'bank_slip', 'label': 'Boleto'},
  ];

  void _submit() {
    final title = _titleController.text.trim();
    final amount = LocalFinancialNlpEngine.cleanAndParseAmount(_amountController.text);

    if (title.isEmpty || amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor, informe a descrição e um valor válido.')),
      );
      return;
    }

    final original = widget.initialTransaction;
    final isInstallment = _selectedPaymentMethod == 'credit_card' && _installments > 1;
    // Built explicitly (not via copyWith) so switching e.g. from credit to Pix
    // can clear installments — copyWith can't set a field back to null.
    final tx = FinancialTransaction(
      id: original?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: title,
      amount: amount,
      type: _selectedType,
      category: _resolvedCategory,
      paymentMethod: _selectedPaymentMethod,
      date: _date,
      installments: isInstallment ? _installments : null,
      currentInstallment: isInstallment ? (original?.currentInstallment ?? 1) : null,
      isRecurrent: _isRecurrent,
      dueDay: _isRecurrent ? (_dueDay ?? _date.day) : null,
      billingDay: original?.billingDay,
      paymentMarginDays: original?.paymentMarginDays,
      recurrenceDuration: _isRecurrent ? original?.recurrenceDuration : null,
      bankSource: original?.bankSource,
      notes: original?.notes,
    );

    widget.onAdd(tx);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bgSurface = widget.isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final primaryTextColor = widget.isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryTextColor = widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;

    return Container(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      decoration: BoxDecoration(
        color: bgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _isEditing ? 'Editar Lançamento' : 'Novo Lançamento',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: primaryTextColor,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, color: secondaryTextColor),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Type Selector (Despesa, Receita, Transferência)
            Row(
              children: [
                _buildTypeButton(TransactionType.expense, 'Despesa', KrezioColors.friendlyOrange),
                const SizedBox(width: 8),
                _buildTypeButton(TransactionType.income, 'Receita', KrezioColors.emeraldGreen),
                const SizedBox(width: 8),
                _buildTypeButton(TransactionType.transfer, 'Transferência', KrezioColors.aiPurple),
              ],
            ),
            const SizedBox(height: 16),

            // Title Field
            TextField(
              controller: _titleController,
              decoration: InputDecoration(
                labelText: 'Descrição / Estabelecimento',
                hintText: 'ex: Supermercado, Aluguel, Salário',
                border: OutlineInputBorder(borderRadius: KrezioTheme.borderRadius),
              ),
            ),
            const SizedBox(height: 12),

            // Amount Field
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Valor (R\$)',
                hintText: '0,00',
                prefixText: 'R\$ ',
                border: OutlineInputBorder(borderRadius: KrezioTheme.borderRadius),
              ),
            ),
            const SizedBox(height: 12),

            // Date
            InkWell(
              borderRadius: KrezioTheme.borderRadius,
              onTap: _pickDate,
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Data',
                  prefixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
                  border: OutlineInputBorder(borderRadius: KrezioTheme.borderRadius),
                ),
                child: Text(
                  '${_date.day.toString().padLeft(2, '0')}/${_date.month.toString().padLeft(2, '0')}/${_date.year}',
                  style: TextStyle(color: primaryTextColor),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Category Chips (if expense)
            if (_selectedType == TransactionType.expense) ...[
              Text(
                'Categoria',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: secondaryTextColor),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _allCategories.map((c) {
                  final isSelected = _selectedCategory == c['id'];
                  return ChoiceChip(
                    avatar: Icon(c['icon'] as IconData, size: 14, color: isSelected ? Colors.white : primaryTextColor),
                    label: Text(c['label'] as String, style: const TextStyle(fontSize: 12)),
                    selected: isSelected,
                    selectedColor: KrezioColors.aiPurple,
                    onSelected: (val) {
                      if (val) setState(() => _selectedCategory = c['id'] as String);
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
            ],

            // Payment Method Selector
            Text(
              'Forma de Pagamento',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: secondaryTextColor),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: _paymentMethods.map((p) {
                final isSelected = _selectedPaymentMethod == p['id'];
                return ChoiceChip(
                  label: Text(p['label']!, style: const TextStyle(fontSize: 12)),
                  selected: isSelected,
                  selectedColor: KrezioColors.aiPurple,
                  onSelected: (val) {
                    if (val) setState(() => _selectedPaymentMethod = p['id']!);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),

            // Credit Card Installments
            if (_selectedPaymentMethod == 'credit_card') ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Parcelamento:', style: TextStyle(color: secondaryTextColor, fontSize: 13)),
                  DropdownButton<int>(
                    value: _installments,
                    items: List.generate(24, (i) => i + 1).map((n) {
                      return DropdownMenuItem<int>(
                        value: n,
                        child: Text(n == 1 ? 'À vista (1x)' : '$n x'),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) setState(() => _installments = val);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],

            // Recurrence Toggle
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Despesa Recorrente / Mensal', style: TextStyle(fontSize: 13)),
              subtitle: Text(
                _isRecurrent ? 'Será computada todo mês automaticamente' : 'Lançamento pontual único',
                style: TextStyle(fontSize: 11, color: secondaryTextColor),
              ),
              value: _isRecurrent,
              activeColor: KrezioColors.emeraldGreen,
              onChanged: (val) => setState(() => _isRecurrent = val),
            ),
            const SizedBox(height: 20),

            // Submit Button
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: KrezioColors.aiPurple,
                  shape: RoundedRectangleBorder(borderRadius: KrezioTheme.borderRadius),
                ),
                child: Text(
                  _isEditing ? 'Salvar Alterações' : 'Salvar Lançamento',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    // Keep the original time of day so same-day ordering in the list doesn't jump.
    setState(() => _date = DateTime(picked.year, picked.month, picked.day, _date.hour, _date.minute, _date.second));
  }

  Widget _buildTypeButton(TransactionType type, String label, Color color) {
    final isSelected = _selectedType == type;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _selectedType = type),
        borderRadius: KrezioTheme.borderRadius,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? color.withOpacity(0.18) : Colors.transparent,
            borderRadius: KrezioTheme.borderRadius,
            border: Border.all(
              color: isSelected ? color : (widget.isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder),
              width: isSelected ? 1.5 : 1,
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? color : (widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText),
            ),
          ),
        ),
      ),
    );
  }
}
