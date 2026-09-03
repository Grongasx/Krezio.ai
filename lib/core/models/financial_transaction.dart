import 'package:flutter/material.dart';
import '../theme/krezio_theme.dart';

enum TransactionType {
  expense,
  income,
  transfer,
}

class FinancialTransaction {
  final String id;
  final String title;
  final double amount;
  final TransactionType type;
  final String category;
  final String paymentMethod;
  final DateTime date;
  final int? installments;
  final int? currentInstallment;
  final bool isRecurrent;
  final int? dueDay;
  final String? recurrenceDuration;
  final String? bankSource;
  final String? notes;

  FinancialTransaction({
    required this.id,
    required this.title,
    required this.amount,
    required this.type,
    required this.category,
    required this.paymentMethod,
    required this.date,
    this.installments,
    this.currentInstallment,
    this.isRecurrent = false,
    this.dueDay,
    this.recurrenceDuration,
    this.bankSource,
    this.notes,
  });

  FinancialTransaction copyWith({
    String? id,
    String? title,
    double? amount,
    TransactionType? type,
    String? category,
    String? paymentMethod,
    DateTime? date,
    int? installments,
    int? currentInstallment,
    bool? isRecurrent,
    int? dueDay,
    String? recurrenceDuration,
    String? bankSource,
    String? notes,
  }) {
    return FinancialTransaction(
      id: id ?? this.id,
      title: title ?? this.title,
      amount: amount ?? this.amount,
      type: type ?? this.type,
      category: category ?? this.category,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      date: date ?? this.date,
      installments: installments ?? this.installments,
      currentInstallment: currentInstallment ?? this.currentInstallment,
      isRecurrent: isRecurrent ?? this.isRecurrent,
      dueDay: dueDay ?? this.dueDay,
      recurrenceDuration: recurrenceDuration ?? this.recurrenceDuration,
      bankSource: bankSource ?? this.bankSource,
      notes: notes ?? this.notes,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'amount': amount,
      'type': type.name,
      'category': category,
      'paymentMethod': paymentMethod,
      'date': date.toIso8601String(),
      'installments': installments,
      'currentInstallment': currentInstallment,
      'isRecurrent': isRecurrent,
      'dueDay': dueDay,
      'recurrenceDuration': recurrenceDuration,
      'bankSource': bankSource,
      'notes': notes,
    };
  }

  factory FinancialTransaction.fromJson(Map<String, dynamic> json) {
    return FinancialTransaction(
      id: json['id'] as String,
      title: json['title'] as String,
      amount: (json['amount'] as num).toDouble(),
      type: TransactionType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => TransactionType.expense,
      ),
      category: json['category'] as String? ?? 'expense_other',
      paymentMethod: json['paymentMethod'] as String? ?? 'pix',
      date: DateTime.parse(json['date'] as String),
      installments: json['installments'] as int?,
      currentInstallment: json['currentInstallment'] as int?,
      isRecurrent: json['isRecurrent'] as bool? ?? false,
      dueDay: json['dueDay'] as int?,
      recurrenceDuration: json['recurrenceDuration'] as String?,
      bankSource: json['bankSource'] as String?,
      notes: json['notes'] as String?,
    );
  }

  IconData get categoryIcon {
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
      case 'salary':
        return Icons.work_outline;
      case 'investment':
        return Icons.trending_up;
      default:
        return Icons.category_outlined;
    }
  }

  String get categoryLabel {
    switch (category) {
      case 'supermarket':
        return 'Supermercado';
      case 'transport':
        return 'Transporte';
      case 'health':
        return 'Saúde';
      case 'leisure':
        return 'Lazer & Comida';
      case 'housing':
        return 'Moradia & Contas';
      case 'education':
        return 'Educação';
      case 'salary':
        return 'Salário';
      case 'investment':
        return 'Investimentos';
      default:
        return 'Outros';
    }
  }

  String get paymentMethodLabel {
    switch (paymentMethod) {
      case 'pix':
        return 'Pix';
      case 'credit_card':
        return installments != null && installments! > 1
            ? 'Crédito (${installments}x)'
            : 'Crédito à vista';
      case 'debit_card':
        return 'Débito';
      case 'cash':
        return 'Dinheiro';
      case 'bank_slip':
        return 'Boleto';
      default:
        return 'Outro';
    }
  }

  Color get categoryColor {
    switch (category) {
      case 'supermarket':
        return const Color(0xFF3B82F6); // Blue
      case 'transport':
        return const Color(0xFFF59E0B); // Amber
      case 'health':
        return const Color(0xFFEC4899); // Pink
      case 'leisure':
        return KrezioColors.aiPurple; // Purple
      case 'housing':
        return const Color(0xFF14B8A6); // Teal
      case 'education':
        return const Color(0xFF6366F1); // Indigo
      case 'salary':
        return KrezioColors.emeraldGreen; // Green
      case 'investment':
        return const Color(0xFF10B981);
      default:
        return KrezioColors.friendlyOrange;
    }
  }
}
