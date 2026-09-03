import 'package:flutter/material.dart';
import '../../../../core/theme/krezio_theme.dart';

class AiInsightCard extends StatelessWidget {
  final String insightText;
  final bool isDark;
  final VoidCallback? onAskAi;

  const AiInsightCard({
    super.key,
    required this.insightText,
    required this.isDark,
    this.onAskAi,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF2E1065), const Color(0xFF1E1B4B)]
              : [const Color(0xFFF3E8FF), const Color(0xFFEDE9FE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: KrezioTheme.borderRadius,
        border: Border.all(
          color: KrezioColors.aiPurple.withOpacity(0.35),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: KrezioColors.aiPurple.withOpacity(0.25),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  color: KrezioColors.aiPurple,
                  size: 16,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Insight do Krezio.ai',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : const Color(0xFF5B21B6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            insightText,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: isDark ? const Color(0xFFE9D5FF) : const Color(0xFF4C1D95),
            ),
          ),
          if (onAskAi != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onAskAi,
                icon: const Icon(Icons.chat_bubble_outline, size: 14, color: KrezioColors.aiPurple),
                label: const Text(
                  'Conversar com a IA',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: KrezioColors.aiPurple),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  backgroundColor: isDark ? Colors.black26 : Colors.white60,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
