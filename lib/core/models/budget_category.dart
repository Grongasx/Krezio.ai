import 'package:flutter/material.dart';
import '../theme/krezio_theme.dart';

class BudgetCategory {
  final String category;
  final String name;
  final double monthlyLimit;
  final double currentSpent;
  final IconData icon;
  final Color color;

  BudgetCategory({
    required this.category,
    required this.name,
    required this.monthlyLimit,
    required this.currentSpent,
    required this.icon,
    required this.color,
  });

  double get percentage => monthlyLimit > 0 ? (currentSpent / monthlyLimit).clamp(0.0, 1.5) : 0.0;
  double get remaining => (monthlyLimit - currentSpent).clamp(0.0, double.infinity);
  bool get isOverBudget => currentSpent > monthlyLimit;
  bool get isNearLimit => currentSpent >= (monthlyLimit * 0.8) && !isOverBudget;

  BudgetCategory copyWith({
    String? category,
    String? name,
    double? monthlyLimit,
    double? currentSpent,
    IconData? icon,
    Color? color,
  }) {
    return BudgetCategory(
      category: category ?? this.category,
      name: name ?? this.name,
      monthlyLimit: monthlyLimit ?? this.monthlyLimit,
      currentSpent: currentSpent ?? this.currentSpent,
      icon: icon ?? this.icon,
      color: color ?? this.color,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'category': category,
      'name': name,
      'monthlyLimit': monthlyLimit,
      'currentSpent': currentSpent,
    };
  }

  factory BudgetCategory.fromJson(Map<String, dynamic> json) {
    final cat = json['category'] as String;
    return BudgetCategory(
      category: cat,
      name: json['name'] as String,
      monthlyLimit: (json['monthlyLimit'] as num).toDouble(),
      currentSpent: (json['currentSpent'] as num?)?.toDouble() ?? 0.0,
      icon: getIconForCategory(cat),
      color: getColorForCategory(cat),
    );
  }

  static IconData getIconForCategory(String category) {
    switch (category) {
      case 'supermarket':
        return Icons.shopping_cart_outlined;
      case 'transport':
        return Icons.directions_car_outlined;
      case 'health':
        return Icons.local_hospital_outlined;
      case 'leisure':
        return Icons.restaurant_outlined;
      case 'housing':
        return Icons.home_outlined;
      case 'education':
        return Icons.school_outlined;
      default:
        return Icons.category_outlined;
    }
  }

  static Color getColorForCategory(String category) {
    switch (category) {
      case 'supermarket':
        return const Color(0xFF3B82F6);
      case 'transport':
        return const Color(0xFFF59E0B);
      case 'health':
        return const Color(0xFFEC4899);
      case 'leisure':
        return KrezioColors.aiPurple;
      case 'housing':
        return const Color(0xFF14B8A6);
      case 'education':
        return const Color(0xFF6366F1);
      default:
        return KrezioColors.friendlyOrange;
    }
  }
}
