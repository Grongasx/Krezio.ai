import 'package:flutter/material.dart';
import '../../frontend/theme/krezio_theme.dart';

class BudgetCategory {
  final String category;
  final String name;
  final double monthlyLimit;
  final double currentSpent;
  final IconData icon;
  final Color color;
  final bool isCustom;

  BudgetCategory({
    required this.category,
    required this.name,
    required this.monthlyLimit,
    required this.currentSpent,
    required this.icon,
    required this.color,
    this.isCustom = false,
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
    bool? isCustom,
  }) {
    return BudgetCategory(
      category: category ?? this.category,
      name: name ?? this.name,
      monthlyLimit: monthlyLimit ?? this.monthlyLimit,
      currentSpent: currentSpent ?? this.currentSpent,
      icon: icon ?? this.icon,
      color: color ?? this.color,
      isCustom: isCustom ?? this.isCustom,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'category': category,
      'name': name,
      'monthlyLimit': monthlyLimit,
      'currentSpent': currentSpent,
      'isCustom': isCustom,
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
      isCustom: json['isCustom'] as bool? ?? false,
    );
  }

  /// Slugifies a user-typed category name into a stable internal code, e.g.
  /// "Pets & Vet" -> "pets_vet". Used when creating a custom category so it
  /// behaves just like a built-in one (transactions/budgets key off this code).
  static String slugify(String name) {
    const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
    const to = 'aaaaaeeeeiiiiooooouuuucn';
    var result = name.toLowerCase().trim();
    for (var i = 0; i < from.length; i++) {
      result = result.replaceAll(from[i], to[i]);
    }
    result = result.replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    return result.isEmpty ? 'custom' : result;
  }

  // Icons/colors for custom (user-created) categories, deterministically picked
  // by name so each one gets a stable, visually distinct look without needing
  // an icon/color picker UI.
  static const List<IconData> _customIcons = [
    Icons.category_outlined,
    Icons.pets_outlined,
    Icons.card_giftcard_outlined,
    Icons.sports_esports_outlined,
    Icons.child_care_outlined,
    Icons.spa_outlined,
    Icons.build_outlined,
    Icons.flight_takeoff_outlined,
    Icons.celebration_outlined,
    Icons.local_cafe_outlined,
  ];

  static const List<Color> _customColors = [
    KrezioColors.friendlyOrange,
    Color(0xFF8B5CF6),
    Color(0xFF06B6D4),
    Color(0xFFF43F5E),
    Color(0xFF84CC16),
    Color(0xFFEAB308),
    Color(0xFF64748B),
    Color(0xFFEC4899),
  ];

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
        return _customIcons[category.hashCode.abs() % _customIcons.length];
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
        return _customColors[category.hashCode.abs() % _customColors.length];
    }
  }
}
