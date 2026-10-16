import 'package:flutter/material.dart';
import '../../../../../backend/services/currency_service.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../../ai/transaction_code.dart';
import '../../../../../backend/models/financial_transaction.dart';

class TransactionListTile extends StatelessWidget {
  final FinancialTransaction transaction;
  final bool isDark;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  const TransactionListTile({
    super.key,
    required this.transaction,
    required this.isDark,
    this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;

    final isIncome = transaction.type == TransactionType.income;
    final isTransfer = transaction.type == TransactionType.transfer;
    final amountColor = isIncome
        ? KrezioColors.emeraldGreen
        : (isTransfer ? KrezioColors.aiPurple : (isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText));

    final prefix = isIncome ? '+ ' : '- ';
    final amountFormatted = '$prefix R\$ ${transaction.amount.toStringAsFixed(2).replaceAll('.', ',')}';

    final dateStr = '${transaction.date.day.toString().padLeft(2, '0')}/${transaction.date.month.toString().padLeft(2, '0')}';

    return Dismissible(
      key: Key(transaction.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: KrezioSpace.xl),
        decoration: BoxDecoration(
          color: KrezioColors.friendlyOrange.withOpacity(0.2),
          borderRadius: KrezioTheme.borderRadius,
        ),
        child: const Icon(Icons.delete_outline, color: KrezioColors.friendlyOrange),
      ),
      onDismissed: (_) {
        onDelete?.call();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: KrezioSpace.sm),
        padding: const EdgeInsets.symmetric(horizontal: KrezioSpace.lg, vertical: KrezioSpace.md),
        decoration: BoxDecoration(
          color: bgSurface,
          borderRadius: KrezioTheme.borderRadius,
          border: Border.all(color: borderColor),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: KrezioTheme.borderRadius,
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(KrezioSpace.md),
                decoration: BoxDecoration(
                  color: transaction.categoryColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  transaction.categoryIcon,
                  color: transaction.categoryColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: KrezioSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      transaction.title,
                      style: TextStyle(
                        fontSize: KrezioFont.body,
                        fontWeight: FontWeight.w600,
                        color: isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: KrezioSpace.xs),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '$dateStr • ${transaction.paymentMethodLabel} • ${TransactionCode.label(transaction.id)}'
                            '${transaction.originalCurrency != null && transaction.originalAmount != null ? ' • ${Currencies.format(transaction.originalCurrency!, transaction.originalAmount!)}' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: KrezioFont.caption,
                              color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                            ),
                          ),
                        ),
                        if (transaction.bankSource != null) ...[
                          const SizedBox(width: KrezioSpace.xs),
                          Text(
                            '(${transaction.bankSource})',
                            style: const TextStyle(
                              fontSize: KrezioFont.micro,
                              color: KrezioColors.aiPurple,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                        if (transaction.isRecurrent) ...[
                          const SizedBox(width: KrezioSpace.xs),
                          const Icon(Icons.repeat, size: 12, color: KrezioColors.emeraldGreen),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              Text(
                amountFormatted,
                style: TextStyle(
                  fontSize: KrezioFont.body,
                  fontWeight: FontWeight.bold,
                  color: amountColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
