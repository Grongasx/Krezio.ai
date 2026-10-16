/// Kind of an account or wallet.
enum AccountKind { checking, savings, wallet, creditCard }

/// Where money is: a bank account, the wallet, savings or a credit card.
/// Every transaction belongs to one ([FinancialTransaction.accountId]; null
/// means the main account).
class FinancialAccount {
  /// Id of the account that exists from the start and holds every record
  /// saved before accounts existed.
  static const String mainId = 'main';

  final String id;
  final String name;
  final AccountKind kind;

  /// An archived account leaves the pickers but keeps its history.
  final bool archived;

  /// Credit card only: the day the invoice closes and the day it is due.
  final int? closingDay;
  final int? dueDay;

  const FinancialAccount({
    required this.id,
    required this.name,
    this.kind = AccountKind.checking,
    this.archived = false,
    this.closingDay,
    this.dueDay,
  });

  static const FinancialAccount main = FinancialAccount(id: mainId, name: 'Conta principal');

  bool get isCreditCard => kind == AccountKind.creditCard;

  FinancialAccount copyWith({String? name, AccountKind? kind, bool? archived, int? closingDay, int? dueDay}) => FinancialAccount(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        archived: archived ?? this.archived,
        closingDay: closingDay ?? this.closingDay,
        dueDay: dueDay ?? this.dueDay,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'archived': archived,
        'closingDay': closingDay,
        'dueDay': dueDay,
      };

  factory FinancialAccount.fromJson(Map<String, dynamic> json) => FinancialAccount(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Conta',
        kind: AccountKind.values.firstWhere((k) => k.name == json['kind'], orElse: () => AccountKind.checking),
        archived: json['archived'] as bool? ?? false,
        closingDay: json['closingDay'] as int?,
        dueDay: json['dueDay'] as int?,
      );

  String get kindLabel => switch (kind) {
        AccountKind.checking => 'Conta corrente',
        AccountKind.savings => 'Poupança',
        AccountKind.wallet => 'Carteira',
        AccountKind.creditCard => 'Cartão de crédito',
      };
}
