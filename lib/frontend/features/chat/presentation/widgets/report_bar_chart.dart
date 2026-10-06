import 'package:flutter/material.dart';
import '../../../../theme/krezio_theme.dart';

/// A lightweight horizontal bar chart for report data that isn't shaped like a
/// category breakdown (debtors by person, bills by title, income vs. expense, etc.),
/// hand-painted the same way as [CategoryDonutChart] so no charting package is needed.
class ReportBarChart extends StatelessWidget {
  final List<MapEntry<String, double>> data;
  final bool isDark;

  const ReportBarChart({
    super.key,
    required this.data,
    required this.isDark,
  });

  static const _palette = [
    KrezioColors.aiPurple,
    Color(0xFF3B82F6),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFFEC4899),
    Color(0xFF14B8A6),
  ];

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();

    final maxValue = data.map((e) => e.value.abs()).fold<double>(0, (a, b) => a > b ? a : b);
    final textColor = isDark ? KrezioColors.darkPrimaryText : KrezioColors.lightPrimaryText;
    final trackColor = (isDark ? Colors.white : Colors.black).withOpacity(0.08);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < data.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == data.length - 1 ? 0 : 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        data[i].key,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: textColor),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'R\$ ${_formatMoney(data[i].value)}',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _palette[i % _palette.length]),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final ratio = maxValue == 0 ? 0.0 : (data[i].value.abs() / maxValue);
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Stack(
                        children: [
                          Container(height: 8, width: constraints.maxWidth, color: trackColor),
                          Container(
                            height: 8,
                            width: constraints.maxWidth * ratio,
                            color: _palette[i % _palette.length],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _formatMoney(double value) {
    final parts = value.abs().toStringAsFixed(2).split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]}.',
    );
    return '${value < 0 ? '-' : ''}$intPart,${parts[1]}';
  }
}
