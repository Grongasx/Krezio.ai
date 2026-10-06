import 'package:flutter/material.dart';
import '../../frontend/theme/krezio_theme.dart';

enum ReminderType {
  loanReceivable,
  dividend,
  billPayment,
  general,
}

class FinancialReminder {
  final String id;
  final String title;
  final String? personName;
  final double? amount;
  final DateTime targetDate;
  final ReminderType type;
  final String? notes;
  final bool isCompleted;
  final DateTime createdAt;
  final DateTime? billingDate;
  final int? paymentMarginDays;

  FinancialReminder({
    required this.id,
    required this.title,
    this.personName,
    this.amount,
    required this.targetDate,
    required this.type,
    this.notes,
    this.isCompleted = false,
    DateTime? createdAt,
    this.billingDate,
    this.paymentMarginDays,
  }) : createdAt = createdAt ?? DateTime.now();

  FinancialReminder copyWith({
    String? id,
    String? title,
    String? personName,
    double? amount,
    DateTime? targetDate,
    ReminderType? type,
    String? notes,
    bool? isCompleted,
    DateTime? createdAt,
    DateTime? billingDate,
    int? paymentMarginDays,
  }) {
    return FinancialReminder(
      id: id ?? this.id,
      title: title ?? this.title,
      personName: personName ?? this.personName,
      amount: amount ?? this.amount,
      targetDate: targetDate ?? this.targetDate,
      type: type ?? this.type,
      notes: notes ?? this.notes,
      isCompleted: isCompleted ?? this.isCompleted,
      createdAt: createdAt ?? this.createdAt,
      billingDate: billingDate ?? this.billingDate,
      paymentMarginDays: paymentMarginDays ?? this.paymentMarginDays,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'personName': personName,
    'amount': amount,
    'targetDate': targetDate.toIso8601String(),
    'type': type.name,
    'notes': notes,
    'isCompleted': isCompleted,
    'createdAt': createdAt.toIso8601String(),
    if (billingDate != null) 'billingDate': billingDate!.toIso8601String(),
    if (paymentMarginDays != null) 'paymentMarginDays': paymentMarginDays,
  };

  factory FinancialReminder.fromJson(Map<String, dynamic> json) {
    return FinancialReminder(
      id: json['id'] as String,
      title: json['title'] as String,
      personName: json['personName'] as String?,
      amount: (json['amount'] as num?)?.toDouble(),
      targetDate: DateTime.parse(json['targetDate'] as String),
      type: ReminderType.values.firstWhere(
        (t) => t.name == json['type'],
        orElse: () => ReminderType.general,
      ),
      notes: json['notes'] as String?,
      isCompleted: json['isCompleted'] as bool? ?? false,
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt'] as String) : DateTime.now(),
      billingDate: json['billingDate'] != null ? DateTime.parse(json['billingDate'] as String) : null,
      paymentMarginDays: json['paymentMarginDays'] as int?,
    );
  }

  IconData get icon {
    switch (type) {
      case ReminderType.loanReceivable:
        return Icons.handshake_outlined;
      case ReminderType.dividend:
        return Icons.trending_up;
      case ReminderType.billPayment:
        return Icons.receipt_long;
      case ReminderType.general:
        return Icons.notifications_active_outlined;
    }
  }

  Color get color {
    switch (type) {
      case ReminderType.loanReceivable:
        return KrezioColors.friendlyOrange;
      case ReminderType.dividend:
        return KrezioColors.emeraldGreen;
      case ReminderType.billPayment:
        return KrezioColors.aiPurple;
      case ReminderType.general:
        return Colors.blueAccent;
    }
  }

  String get typeLabel {
    switch (type) {
      case ReminderType.loanReceivable:
        return 'Empréstimo a Receber';
      case ReminderType.dividend:
        return 'Lembrete de Dividendos';
      case ReminderType.billPayment:
        return 'Conta a Pagar';
      case ReminderType.general:
        return 'Lembrete Financeiro';
    }
  }
}
