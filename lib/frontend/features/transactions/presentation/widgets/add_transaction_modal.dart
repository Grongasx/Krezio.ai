import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../../backend/services/money.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../widgets/krezio_components.dart';
import '../../../../../backend/models/financial_transaction.dart';
import '../../../../../backend/models/budget_category.dart';
import '../../../../../backend/models/financial_account.dart';
import '../../../../../ai/local_nlp_engine.dart';
import '../../../../../backend/services/currency_service.dart';

class AddTransactionModal extends StatefulWidget {
  final bool isDark;
  final Function(FinancialTransaction) onAdd;

  /// When set, the modal edits this transaction instead of creating a new one:
  /// fields start pre-filled and [onAdd] receives the updated copy (same id).
  final FinancialTransaction? initialTransaction;

  /// User-created categories, offered as chips next to the built-in ones.
  final List<BudgetCategory> customCategories;

  /// Accounts to pick from; the picker shows when there is more than one.
  final List<FinancialAccount> accounts;

  const AddTransactionModal({
    super.key,
    required this.isDark,
    required this.onAdd,
    this.initialTransaction,
    this.customCategories = const [],
    this.accounts = const [],
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
  int? _dueBusinessDay;
  String _recurrenceFrequency = 'monthly'; // 'monthly', 'business_day', 'weekly', 'biweekly'
  String _recurrenceWeekday = 'Toda Segunda-feira';
  String _recurrenceBiweekly = 'Quinzenal (dias 1 e 15)';
  String _recurrencePeriod = 'Contínua';
  String _accountId = FinancialAccount.mainId;
  String _currency = Currencies.base;
  final _rateController = TextEditingController();
  late DateTime _date;

  static const List<String> _weekdays = [
    'Toda Segunda-feira',
    'Toda Terça-feira',
    'Toda Quarta-feira',
    'Toda Quinta-feira',
    'Toda Sexta-feira',
    'Todo Sábado',
    'Todo Domingo',
  ];

  static const List<String> _biweeklyOptions = [
    'Quinzenal (dias 1 e 15)',
    'Quinzenal (dias 5 e 20)',
    'Quinzenal (a cada 15 dias)',
  ];

  static const List<String> _periodOptions = [
    'Contínua',
    '3 meses',
    '6 meses',
    '12 meses',
  ];

  bool get _isEditing => widget.initialTransaction != null;

  @override
  void initState() {
    super.initState();
    final tx = widget.initialTransaction;
    _date = tx?.date ?? DateTime.now();
    _dueDay = _date.day;
    if (tx == null) return;
    _titleController.text = tx.title;
    _amountController.text = Money.groupedDecimal(tx.amount);
    _selectedType = tx.type == TransactionType.transfer ? TransactionType.expense : tx.type;
    _selectedCategory = tx.category;
    _selectedPaymentMethod = _paymentMethods.any((p) => p['id'] == tx.paymentMethod) ? tx.paymentMethod : 'pix';
    _installments = tx.installments ?? 1;
    _isRecurrent = tx.isRecurrent;
    _dueDay = tx.dueDay ?? tx.date.day;
    _dueBusinessDay = tx.dueBusinessDay;
    if (tx.dueBusinessDay != null) {
      _recurrenceFrequency = 'business_day';
    } else if (tx.recurrenceDuration != null) {
      final dur = tx.recurrenceDuration!;
      if (dur.startsWith('Toda ') || dur.startsWith('Todo ')) {
        _recurrenceFrequency = 'weekly';
        final match = _weekdays.firstWhere(
          (w) => dur.startsWith(w),
          orElse: () => _weekdays.first,
        );
        _recurrenceWeekday = match;
      } else if (dur.startsWith('Quinzenal')) {
        _recurrenceFrequency = 'biweekly';
        final match = _biweeklyOptions.firstWhere(
          (b) => dur.startsWith(b),
          orElse: () => _biweeklyOptions.first,
        );
        _recurrenceBiweekly = match;
      }
      for (final p in _periodOptions) {
        if (dur.contains(p)) _recurrencePeriod = p;
      }
    }
    _accountId = tx.account;
    if (tx.originalCurrency != null && tx.originalAmount != null) {
      _currency = tx.originalCurrency!;
      _amountController.text = Money.groupedDecimal(tx.originalAmount!);
      _rateController.text = (tx.exchangeRate ?? 1).toStringAsFixed(4).replaceAll('.', ',');
    }
  }

  String _buildRecurrenceSummary() {
    String base;
    switch (_recurrenceFrequency) {
      case 'business_day':
        base = 'Todo ${_dueBusinessDay ?? 5}º dia útil do mês';
        break;
      case 'weekly':
        base = _recurrenceWeekday;
        break;
      case 'biweekly':
        base = _recurrenceBiweekly;
        break;
      case 'monthly':
      default:
        base = 'Todo mês no dia ${_dueDay ?? _date.day}';
        break;
    }
    return _recurrencePeriod == 'Contínua' ? base : '$base • $_recurrencePeriod';
  }

  /// The typed value in reais, at the typed rate.
  double? get _converted {
    final v = LocalFinancialNlpEngine.cleanAndParseAmount(_amountController.text);
    final r = LocalFinancialNlpEngine.cleanAndParseAmount(_rateController.text);
    return v == null || r == null ? null : Currencies.toBase(v, r);
  }

  Future<void> _setCurrency(String c) async {
    setState(() {
      _currency = c;
      // Re-normalize the typed value so the BRL mask keeps working.
      final v = LocalFinancialNlpEngine.cleanAndParseAmount(_amountController.text);
      if (c == Currencies.base && v != null) _amountController.text = Money.groupedDecimal(v);
    });
    if (c == Currencies.base) return;
    final rate = await CurrencyService().rateToBrl(c);
    if (rate != null && mounted && _currency == c) {
      setState(() => _rateController.text = rate.toStringAsFixed(4).replaceAll('.', ','));
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _amountController.dispose();
    _rateController.dispose();
    super.dispose();
  }

  /// Categories offered for the selected type: expenses never show "Salário"
  /// and incomes never show "Supermercado".
  List<Map<String, dynamic>> get _allCategories => _selectedType == TransactionType.income
      ? _incomeCategories
      : [
          ..._expenseCategories,
          ...widget.customCategories.map((c) => {'id': c.category, 'label': c.name, 'icon': c.icon}),
        ];

  static const _incomeIds = {'salary', 'investment', 'income_other'};

  /// Category actually saved, always consistent with the selected type.
  String get _resolvedCategory {
    if (_selectedType == TransactionType.transfer) return 'transfer';
    final isIncomeCat = _incomeIds.contains(_selectedCategory);
    if (_selectedType == TransactionType.income) {
      if (isIncomeCat) return _selectedCategory;
      final original = widget.initialTransaction;
      if (original != null && original.type == TransactionType.income) return original.category;
      return 'salary';
    }
    return isIncomeCat ? 'expense_other' : _selectedCategory;
  }

  /// Switches type and picks a sensible category of that type.
  void _setType(TransactionType type) {
    setState(() {
      _selectedType = type;
      final ids = _allCategories.map((c) => c['id']).toSet();
      if (!ids.contains(_selectedCategory)) {
        _selectedCategory = type == TransactionType.income ? 'salary' : 'supermarket';
      }
    });
  }

  static final List<Map<String, dynamic>> _expenseCategories = [
    {'id': 'supermarket', 'label': 'Supermercado', 'icon': Icons.shopping_cart_outlined},
    {'id': 'transport', 'label': 'Transporte', 'icon': Icons.directions_car_outlined},
    {'id': 'leisure', 'label': 'Lazer/Comida', 'icon': Icons.restaurant_outlined},
    {'id': 'housing', 'label': 'Moradia', 'icon': Icons.home_outlined},
    {'id': 'health', 'label': 'Saúde', 'icon': Icons.local_hospital_outlined},
    {'id': 'education', 'label': 'Educação', 'icon': Icons.school_outlined},
    {'id': 'expense_other', 'label': 'Outros', 'icon': Icons.more_horiz},
  ];

  static final List<Map<String, dynamic>> _incomeCategories = [
    {'id': 'salary', 'label': 'Salário', 'icon': Icons.work_outline},
    {'id': 'investment', 'label': 'Investimentos', 'icon': Icons.trending_up},
    {'id': 'income_other', 'label': 'Outras receitas', 'icon': Icons.attach_money},
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
    final typed = LocalFinancialNlpEngine.cleanAndParseAmount(_amountController.text);
    final foreign = _currency != Currencies.base;
    final rate = foreign ? LocalFinancialNlpEngine.cleanAndParseAmount(_rateController.text) : 1.0;
    if (foreign && (rate == null || rate <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Informe a cotação (quantos reais vale 1 unidade da moeda).')),
      );
      return;
    }
    final amount = typed == null ? null : (foreign ? Currencies.toBase(typed, rate!) : typed);

    if (title.isEmpty || amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor, informe a descrição e um valor válido.')),
      );
      return;
    }

    final original = widget.initialTransaction;
    final isInstallment = _selectedPaymentMethod == 'credit_card' && _installments > 1;
    final resolvedDueDay = _isRecurrent && _recurrenceFrequency == 'monthly'
        ? (_dueDay ?? _date.day)
        : null;
    final resolvedBusinessDay = _isRecurrent && _recurrenceFrequency == 'business_day'
        ? (_dueBusinessDay ?? 5)
        : null;
    final resolvedRecurrenceDuration = _isRecurrent ? _buildRecurrenceSummary() : null;

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
      dueDay: resolvedDueDay,
      dueBusinessDay: resolvedBusinessDay,
      billingDay: original?.billingDay,
      paymentMarginDays: original?.paymentMarginDays,
      recurrenceDuration: resolvedRecurrenceDuration,
      bankSource: original?.bankSource,
      notes: original?.notes,
      accountId: _accountId == FinancialAccount.mainId ? null : _accountId,
      toAccountId: original?.toAccountId,
      originalCurrency: foreign ? _currency : null,
      originalAmount: foreign ? typed : null,
      exchangeRate: foreign ? rate : null,
    );

    widget.onAdd(tx);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bgSurface = widget.isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final primaryTextColor = widget.isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final secondaryTextColor = widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText;
    final borderColor = widget.isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
    final media = MediaQuery.of(context);
    final maxModalHeight = (media.size.height * 0.84).clamp(380.0, 760.0);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): _submit,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _submit,
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxModalHeight,
          maxWidth: 520,
        ),
        child: Container(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 12,
            bottom: media.viewInsets.bottom + 16,
          ),
          decoration: BoxDecoration(
            color: bgSurface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: BoxDecoration(
                    color: secondaryTextColor.withOpacity(0.35),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _isEditing ? 'Editar Lançamento' : 'Novo Lançamento',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: KrezioFont.title,
                        fontWeight: FontWeight.bold,
                        color: primaryTextColor,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, color: secondaryTextColor),
                  ),
                ],
              ),
              const SizedBox(height: KrezioSpace.sm),

              // Type Selector (Despesa e Receita — sem Transferência)
              Row(
                children: [
                  _buildTypeButton(TransactionType.expense, 'Despesa', KrezioColors.friendlyOrange),
                  const SizedBox(width: KrezioSpace.sm),
                  _buildTypeButton(TransactionType.income, 'Receita', KrezioColors.emeraldGreen),
                ],
              ),
              const SizedBox(height: KrezioSpace.md),

              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title Field
                      TextField(
                        controller: _titleController,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) {
                          if (_amountController.text.trim().isEmpty) {
                            FocusScope.of(context).nextFocus();
                          } else {
                            _submit();
                          }
                        },
                        decoration: InputDecoration(
                          labelText: 'Descrição / Estabelecimento',
                          hintText: 'ex: Supermercado, Aluguel, Salário',
                          border: OutlineInputBorder(borderRadius: KrezioTheme.borderRadius),
                        ),
                      ),
                      const SizedBox(height: KrezioSpace.md),

                      // Amount Field (+ currency; totals are always in reais)
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _amountController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => _submit(),
                              inputFormatters: _currency == Currencies.base
                                  ? const [BrlCurrencyInputFormatter()]
                                  : null,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                labelText: 'Valor (${Currencies.symbols[_currency]})',
                                hintText: '0,00',
                                prefixText: '${Currencies.symbols[_currency]} ',
                                border: OutlineInputBorder(borderRadius: KrezioTheme.borderRadius),
                              ),
                            ),
                          ),
                          const SizedBox(width: KrezioSpace.sm),
                          DropdownButton<String>(
                            value: _currency,
                            underline: const SizedBox.shrink(),
                            items: [for (final c in Currencies.symbols.keys) DropdownMenuItem(value: c, child: Text(c))],
                            onChanged: (c) {
                              if (c != null) _setCurrency(c);
                            },
                          ),
                        ],
                      ),
                      if (_currency != Currencies.base) ...[
                        const SizedBox(height: KrezioSpace.sm),
                        TextField(
                          controller: _rateController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _submit(),
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: 'Cotação do dia (R\$ por 1 ${Currencies.names[_currency]})',
                          helperText: _converted == null ? 'Buscando a cotação…' : '= ${Currencies.format('BRL', _converted!)} no seu saldo',
                          border: OutlineInputBorder(borderRadius: KrezioTheme.borderRadius),
                        ),
                      ),
                    ],
                    const SizedBox(height: KrezioSpace.md),

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
                    const SizedBox(height: KrezioSpace.md),

                    // Category Chips (filtered by type)
                    if (_selectedType != TransactionType.transfer) ...[
                      Text(
                        'Categoria',
                        style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: secondaryTextColor),
                      ),
                      const SizedBox(height: KrezioSpace.sm),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: _allCategories.map((c) {
                          final isSelected = _selectedCategory == c['id'];
                          return ChoiceChip(
                            avatar: Icon(c['icon'] as IconData, size: 14, color: isSelected ? Colors.white : primaryTextColor),
                            label: Text(c['label'] as String, style: const TextStyle(fontSize: KrezioFont.small)),
                            selected: isSelected,
                            selectedColor: KrezioColors.aiPurple,
                            onSelected: (val) {
                              if (val) setState(() => _selectedCategory = c['id'] as String);
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: KrezioSpace.md),
                    ],

                    // Payment Method Selector
                    Text(
                      'Forma de Pagamento',
                      style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: secondaryTextColor),
                    ),
                    const SizedBox(height: KrezioSpace.sm),
                    Wrap(
                      spacing: 6,
                      children: _paymentMethods.map((p) {
                        final isSelected = _selectedPaymentMethod == p['id'];
                        return ChoiceChip(
                          label: Text(p['label']!, style: const TextStyle(fontSize: KrezioFont.small)),
                          selected: isSelected,
                          selectedColor: KrezioColors.aiPurple,
                          onSelected: (val) {
                            if (val) setState(() => _selectedPaymentMethod = p['id']!);
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: KrezioSpace.md),

                    // Account
                    if (widget.accounts.length > 1) ...[
                      Text(
                        'Conta',
                        style: TextStyle(fontSize: KrezioFont.small, fontWeight: FontWeight.bold, color: secondaryTextColor),
                      ),
                      const SizedBox(height: KrezioSpace.sm),
                      Wrap(
                        spacing: 6,
                        children: widget.accounts.map((a) {
                          return ChoiceChip(
                            label: Text(a.name, style: const TextStyle(fontSize: KrezioFont.small)),
                            selected: _accountId == a.id,
                            selectedColor: KrezioColors.aiPurple,
                            onSelected: (val) {
                              if (!val) return;
                              setState(() {
                                _accountId = a.id;
                                if (a.isCreditCard) _selectedPaymentMethod = 'credit_card';
                              });
                            },
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: KrezioSpace.md),
                    ],

                    // Credit Card Installments
                    if (_selectedPaymentMethod == 'credit_card') ...[
                      if (_isEditing && (widget.initialTransaction!.installments ?? 1) > 1) ...[
                        Text(
                          'Compra parcelada: a mudança vale para todas as parcelas.',
                          style: TextStyle(fontSize: KrezioFont.caption, color: secondaryTextColor),
                        ),
                        const SizedBox(height: KrezioSpace.xs),
                      ],
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Parcelamento:', style: TextStyle(color: secondaryTextColor, fontSize: KrezioFont.bodySmall)),
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
                      const SizedBox(height: KrezioSpace.sm),
                    ],

                    // Recurrence Toggle + Detailed Configuration
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        _selectedType == TransactionType.income
                            ? 'Receita Recorrente / Fixa'
                            : 'Despesa Recorrente / Fixa',
                        style: const TextStyle(fontSize: KrezioFont.bodySmall, fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text(
                        _isRecurrent ? _buildRecurrenceSummary() : 'Lançamento pontual único',
                        style: TextStyle(
                          fontSize: KrezioFont.caption,
                          color: _isRecurrent ? KrezioColors.emeraldGreen : secondaryTextColor,
                        ),
                      ),
                      value: _isRecurrent,
                      activeColor: KrezioColors.emeraldGreen,
                      onChanged: (val) => setState(() => _isRecurrent = val),
                    ),

                    if (_isRecurrent) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(KrezioSpace.md),
                        margin: const EdgeInsets.only(bottom: KrezioSpace.md),
                        decoration: BoxDecoration(
                          color: KrezioColors.aiPurple.withOpacity(0.06),
                          borderRadius: KrezioTheme.borderRadius,
                          border: Border.all(color: borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.repeat, size: 16, color: KrezioColors.aiPurple),
                                const SizedBox(width: 6),
                                Text(
                                  'Detalhes da Recorrência',
                                  style: TextStyle(
                                    fontSize: KrezioFont.small,
                                    fontWeight: FontWeight.bold,
                                    color: primaryTextColor,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: KrezioSpace.sm),
                            Text(
                              'Frequência de repetição:',
                              style: TextStyle(fontSize: KrezioFont.caption, color: secondaryTextColor),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                ChoiceChip(
                                  label: const Text('Todo mês', style: TextStyle(fontSize: KrezioFont.caption)),
                                  selected: _recurrenceFrequency == 'monthly',
                                  selectedColor: KrezioColors.aiPurple,
                                  onSelected: (_) => setState(() => _recurrenceFrequency = 'monthly'),
                                ),
                                ChoiceChip(
                                  label: const Text('Dia útil', style: TextStyle(fontSize: KrezioFont.caption)),
                                  selected: _recurrenceFrequency == 'business_day',
                                  selectedColor: KrezioColors.aiPurple,
                                  onSelected: (_) => setState(() {
                                    _recurrenceFrequency = 'business_day';
                                    _dueBusinessDay ??= 5;
                                  }),
                                ),
                                ChoiceChip(
                                  label: const Text('Toda semana', style: TextStyle(fontSize: KrezioFont.caption)),
                                  selected: _recurrenceFrequency == 'weekly',
                                  selectedColor: KrezioColors.aiPurple,
                                  onSelected: (_) => setState(() => _recurrenceFrequency = 'weekly'),
                                ),
                                ChoiceChip(
                                  label: const Text('Quinzenal', style: TextStyle(fontSize: KrezioFont.caption)),
                                  selected: _recurrenceFrequency == 'biweekly',
                                  selectedColor: KrezioColors.aiPurple,
                                  onSelected: (_) => setState(() => _recurrenceFrequency = 'biweekly'),
                                ),
                              ],
                            ),
                            const SizedBox(height: KrezioSpace.sm),

                            if (_recurrenceFrequency == 'monthly')
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Qual dia do mês se repete?',
                                    style: TextStyle(fontSize: KrezioFont.small, color: secondaryTextColor),
                                  ),
                                  DropdownButton<int>(
                                    value: (_dueDay ?? _date.day).clamp(1, 31),
                                    items: List.generate(31, (i) => i + 1)
                                        .map((d) => DropdownMenuItem(value: d, child: Text('Todo dia $d')))
                                        .toList(),
                                    onChanged: (d) {
                                      if (d != null) setState(() => _dueDay = d);
                                    },
                                  ),
                                ],
                              ),

                            if (_recurrenceFrequency == 'business_day')
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Qual dia útil do mês?',
                                    style: TextStyle(fontSize: KrezioFont.small, color: secondaryTextColor),
                                  ),
                                  DropdownButton<int>(
                                    value: (_dueBusinessDay ?? 5).clamp(1, 20),
                                    items: List.generate(15, (i) => i + 1)
                                        .map((d) => DropdownMenuItem(value: d, child: Text('$dº dia útil')))
                                        .toList(),
                                    onChanged: (d) {
                                      if (d != null) setState(() => _dueBusinessDay = d);
                                    },
                                  ),
                                ],
                              ),

                            if (_recurrenceFrequency == 'weekly') ...[
                              Text(
                                'Qual dia da semana se repete?',
                                style: TextStyle(fontSize: KrezioFont.caption, color: secondaryTextColor),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: _weekdays.map((day) {
                                  final selected = _recurrenceWeekday == day;
                                  return ChoiceChip(
                                    label: Text(day, style: const TextStyle(fontSize: KrezioFont.caption)),
                                    selected: selected,
                                    selectedColor: KrezioColors.emeraldGreen,
                                    onSelected: (_) => setState(() => _recurrenceWeekday = day),
                                  );
                                }).toList(),
                              ),
                            ],

                            if (_recurrenceFrequency == 'biweekly') ...[
                              Text(
                                'Como se repete quinzenalmente?',
                                style: TextStyle(fontSize: KrezioFont.caption, color: secondaryTextColor),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: _biweeklyOptions.map((opt) {
                                  final selected = _recurrenceBiweekly == opt;
                                  return ChoiceChip(
                                    label: Text(opt, style: const TextStyle(fontSize: KrezioFont.caption)),
                                    selected: selected,
                                    selectedColor: KrezioColors.emeraldGreen,
                                    onSelected: (_) => setState(() => _recurrenceBiweekly = opt),
                                  );
                                }).toList(),
                              ),
                            ],

                            const SizedBox(height: KrezioSpace.sm),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Duração da recorrência:',
                                  style: TextStyle(fontSize: KrezioFont.small, color: secondaryTextColor),
                                ),
                                DropdownButton<String>(
                                  value: _recurrencePeriod,
                                  items: _periodOptions
                                      .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                                      .toList(),
                                  onChanged: (p) {
                                    if (p != null) setState(() => _recurrencePeriod = p);
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: KrezioSpace.md),

            // Submit Button (always visible at bottom of bounded panel)
            KrezioButton(
              label: _isEditing ? 'Salvar Alterações' : 'Salvar Lançamento',
              expand: true,
              onPressed: _submit,
            ),
          ],
        ),
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
        onTap: () => _setType(type),
        borderRadius: KrezioTheme.borderRadius,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: KrezioSpace.sm),
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
              fontSize: KrezioFont.small,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? color : (widget.isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText),
            ),
          ),
        ),
      ),
    );
  }
}
