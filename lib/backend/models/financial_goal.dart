import 'package:flutter/material.dart';
import '../../frontend/theme/krezio_theme.dart';

/// A savings goal the user is putting money aside for (e.g. "Viagem para o Japão",
/// target R$ 5.000,00 by December). Distinct from [BudgetCategory], which caps
/// monthly spending in a category rather than accumulating toward a target.
class FinancialGoal {
  final String id;
  final String title;
  final double targetAmount;
  final double savedAmount;
  final DateTime? targetDate;
  final DateTime createdAt;
  final bool isCompleted;

  FinancialGoal({
    required this.id,
    required this.title,
    required this.targetAmount,
    this.savedAmount = 0.0,
    this.targetDate,
    DateTime? createdAt,
    this.isCompleted = false,
  }) : createdAt = createdAt ?? DateTime.now();

  double get remaining => (targetAmount - savedAmount).clamp(0.0, double.infinity);
  double get progress => targetAmount > 0 ? (savedAmount / targetAmount).clamp(0.0, 1.0) : 0.0;
  bool get isReached => savedAmount >= targetAmount;

  /// Suggested monthly contribution to reach the goal by [targetDate], or null
  /// when there's no target date or it has already passed.
  double? get suggestedMonthlyContribution {
    if (targetDate == null) return null;
    final now = DateTime.now();
    final monthsLeft = (targetDate!.year - now.year) * 12 + (targetDate!.month - now.month);
    if (monthsLeft <= 0) return null;
    return remaining / monthsLeft;
  }

  FinancialGoal copyWith({
    String? id,
    String? title,
    double? targetAmount,
    double? savedAmount,
    DateTime? targetDate,
    DateTime? createdAt,
    bool? isCompleted,
  }) {
    return FinancialGoal(
      id: id ?? this.id,
      title: title ?? this.title,
      targetAmount: targetAmount ?? this.targetAmount,
      savedAmount: savedAmount ?? this.savedAmount,
      targetDate: targetDate ?? this.targetDate,
      createdAt: createdAt ?? this.createdAt,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'targetAmount': targetAmount,
    'savedAmount': savedAmount,
    if (targetDate != null) 'targetDate': targetDate!.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'isCompleted': isCompleted,
  };

  factory FinancialGoal.fromJson(Map<String, dynamic> json) {
    return FinancialGoal(
      id: json['id'] as String,
      title: json['title'] as String,
      targetAmount: (json['targetAmount'] as num).toDouble(),
      savedAmount: (json['savedAmount'] as num?)?.toDouble() ?? 0.0,
      targetDate: json['targetDate'] != null ? DateTime.parse(json['targetDate'] as String) : null,
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt'] as String) : DateTime.now(),
      isCompleted: json['isCompleted'] as bool? ?? false,
    );
  }

  static const List<Color> palette = [
    KrezioColors.aiPurple,
    Color(0xFF3B82F6),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFFEC4899),
    Color(0xFF14B8A6),
  ];

  Color colorFor(int index) => palette[index % palette.length];
}
