import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';
import '../../../../../backend/services/money.dart';

class MetricSummaryCard extends StatelessWidget {
  final String title;
  final double amount;
  final IconData icon;
  final Color iconColor;
  final bool isDark;
  final bool isLarge;
  final bool hideAmount;
  final VoidCallback? onTogglePrivacy;

  const MetricSummaryCard({
    super.key,
    required this.title,
    required this.amount,
    required this.icon,
    required this.iconColor,
    required this.isDark,
    this.isLarge = false,
    this.hideAmount = false,
    this.onTogglePrivacy,
  });

  @override
  Widget build(BuildContext context) {
    final bgSurface = isDark ? KrezioColors.darkSurface : KrezioColors.lightSurface;
    final borderColor = isDark ? KrezioColors.darkBorder : KrezioColors.lightBorder;
    final amountStr = hideAmount ? '••••' : Money.brl(amount);

    return Container(
      padding: EdgeInsets.all(isLarge ? KrezioSpace.xl : KrezioSpace.lg),
      decoration: BoxDecoration(
        color: isLarge ? null : bgSurface,
        gradient: isLarge
            ? LinearGradient(
                colors: isDark
                    ? [const Color(0xFF231F33), KrezioColors.darkSurface]
                    : [const Color(0xFFFDFBFF), KrezioColors.lightSurface],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        borderRadius: KrezioTheme.borderRadius,
        border: Border.all(
          color: isLarge ? KrezioColors.aiPurple.withOpacity(isDark ? 0.35 : 0.25) : borderColor,
          width: isLarge ? 1.2 : 1.0,
        ),
        boxShadow: isDark
            ? (isLarge
                ? [
                    BoxShadow(
                      color: KrezioColors.aiPurple.withOpacity(0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : [])
            : [
                BoxShadow(
                  color: Colors.black.withOpacity(isLarge ? 0.06 : 0.04),
                  blurRadius: isLarge ? 14 : 10,
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
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: isLarge ? KrezioFont.bodySmall : KrezioFont.caption,
                    fontWeight: FontWeight.w600,
                    color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                  ),
                ),
              ),
              if (onTogglePrivacy != null) ...[
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: hideAmount ? 'Mostrar valores' : 'Ocultar valores',
                  onPressed: onTogglePrivacy,
                  icon: Icon(
                    hideAmount ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    size: 18,
                    color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                  ),
                ),
                const SizedBox(width: KrezioSpace.xs),
              ] else
                const SizedBox(width: KrezioSpace.xs),
              Container(
                padding: const EdgeInsets.all(KrezioSpace.sm),
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: isLarge ? 18 : 14),
              ),
            ],
          ),
          SizedBox(height: isLarge ? 10 : 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              amountStr,
              semanticsLabel: hideAmount ? 'Valor oculto' : null,
              style: TextStyle(
                fontSize: isLarge ? 34 : 16,
                fontFeatures: const [FontFeature.tabularFigures()],
                fontWeight: FontWeight.bold,
                color: isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
