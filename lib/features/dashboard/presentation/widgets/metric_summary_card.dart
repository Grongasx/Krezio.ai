import 'package:flutter/material.dart';
import '../../../../core/theme/krezio_theme.dart';

class MetricSummaryCard extends StatelessWidget {
  final String title;
  final double amount;
  final IconData icon;
  final Color iconColor;
  final bool isDark;
  final bool isLarge;

  const MetricSummaryCard({
    super.key,
    required this.title,
    required this.amount,
    required this.icon,
    required this.iconColor,
    required this.isDark,
    this.isLarge = false,
  });

  @override
  Widget build(BuildContext context) {
    final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
    final amountStr = 'R\$ ${amount.toStringAsFixed(2).replaceAll('.', ',')}';

    return Container(
      padding: EdgeInsets.all(isLarge ? 20 : 14),
      decoration: BoxDecoration(
        color: bgSurface,
        borderRadius: KrezioTheme.borderRadius,
        border: Border.all(color: borderColor),
        boxShadow: isDark
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                )
              ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: isLarge ? 13 : 11,
                  fontWeight: FontWeight.w500,
                  color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                ),
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: isLarge ? 18 : 14),
              ),
            ],
          ),
          SizedBox(height: isLarge ? 12 : 6),
          Text(
            amountStr,
            style: TextStyle(
              fontSize: isLarge ? 24 : 16,
              fontWeight: FontWeight.bold,
              color: isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText,
              letterSpacing: -0.5,
            ),
          ),
        ],
      ),
    );
  }
}
