import 'package:flutter/material.dart';
import '../../../../core/theme/krezio_theme.dart';
import '../../../../core/models/financial_transaction.dart';

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
        padding: const EdgeInsets.only(right: 20),
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
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                padding: const EdgeInsets.all(10),
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
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      transaction.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          '$dateStr • ${transaction.paymentMethodLabel}',
                          style: TextStyle(
                            fontSize: 11,
                            color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                          ),
                        ),
                        if (transaction.bankSource != null) ...[
                          const SizedBox(width: 4),
                          Text(
                            '(${transaction.bankSource})',
                            style: const TextStyle(
                              fontSize: 10,
                              color: KrezioColors.aiPurple,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                        if (transaction.isRecurrent) ...[
                          const SizedBox(width: 4),
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
                  fontSize: 14,
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
