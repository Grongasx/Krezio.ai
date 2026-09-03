import 'dart:math';
import 'package:flutter/material.dart';
import '../../../../core/theme/krezio_theme.dart';
import '../../../../core/models/financial_transaction.dart';

class CategoryDonutChart extends StatelessWidget {
  final Map<String, double> categoryData;
  final bool isDark;

  const CategoryDonutChart({
    super.key,
    required this.categoryData,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final total = categoryData.values.fold(0.0, (a, b) => a + b);

    if (total == 0 || categoryData.isEmpty) {
      return Container(
        height: 180,
        alignment: Alignment.center,
        child: Text(
          'Nenhuma despesa registrada este mês.',
          style: TextStyle(
            color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
            fontSize: 13,
          ),
        ),
      );
    }

    final sortedEntries = categoryData.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      children: [
        SizedBox(
          height: 160,
          width: 160,
          child: CustomPaint(
            painter: _DonutChartPainter(
              entries: sortedEntries,
              total: total,
              isDark: isDark,
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Total',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'R\$ ${total >= 1000 ? '${(total / 1000).toStringAsFixed(1)}k' : total.toStringAsFixed(0)}',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: sortedEntries.take(4).map((e) {
            final percentage = (e.value / total * 100).toStringAsFixed(0);
            final dummyTx = FinancialTransaction(
              id: '',
              title: '',
              amount: 0,
              type: TransactionType.expense,
              category: e.key,
              paymentMethod: '',
              date: DateTime.now(),
            );
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: dummyTx.categoryColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '${dummyTx.categoryLabel} ($percentage%)',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? KrezioColors.darkSecondaryText : KrezioColors.lightSecondaryText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _DonutChartPainter extends CustomPainter {
  final List<MapEntry<String, double>> entries;
  final double total;
  final bool isDark;

  _DonutChartPainter({
    required this.entries,
    required this.total,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width / 2, size.height / 2);
    const strokeWidth = 22.0;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    double startAngle = -pi / 2;

    for (final entry in entries) {
      final sweepAngle = (entry.value / total) * 2 * pi;
      final dummyTx = FinancialTransaction(
        id: '',
        title: '',
        amount: 0,
        type: TransactionType.expense,
        category: entry.key,
        paymentMethod: '',
        date: DateTime.now(),
      );

      paint.color = dummyTx.categoryColor;

      // Draw arc with a small gap
      final gap = 0.04;
      if (sweepAngle > gap) {
        canvas.drawArc(
          Rect.fromCircle(center: center, radius: radius - strokeWidth / 2),
          startAngle + (gap / 2),
          sweepAngle - gap,
          false,
          paint,
        );
      }
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutChartPainter oldDelegate) {
    return oldDelegate.total != total || oldDelegate.entries != entries;
  }
}
