import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/chat_action_history.dart';
import 'package:krezio_ai/backend/config/app_environment.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/money.dart';
import 'package:krezio_ai/backend/services/persistence_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('BRL agrupa milhares e preserva sinal e arredondamento de parcelas', () {
    expect(Money.brl(1948.4), 'R\$ 1.948,40');
    expect(Money.brl(-1948.4), '-R\$ 1.948,40');
    expect(Money.brl(2611.60 / 16), 'R\$ 163,23');
    expect(Money.decimal(-1948.4), '-1948,40');
  });

  test('homologação só é reativada depois do sétimo toque consecutivo', () {
    final initial = EnvironmentConfig.current;
    addTearDown(() => EnvironmentConfig.setEnvironment(initial));
    EnvironmentConfig.setEnvironment(AppEnvironment.production);
    final now = DateTime(2026, 10, 20);
    for (var i = 0; i < 6; i++) {
      expect(
        EnvironmentConfig.tapVersion(
          now: now.add(Duration(milliseconds: i * 100)),
        ),
        isFalse,
      );
    }
    expect(EnvironmentConfig.isProduction, isTrue);
    expect(
      EnvironmentConfig.tapVersion(
        now: now.add(const Duration(milliseconds: 600)),
      ),
      isTrue,
    );
    expect(EnvironmentConfig.isHomologation, isTrue);
  });

  test(
    'contas, modo local, dados legados e exemplos ficam separados',
    () async {
      final a = FinancialRepository(
        persistence: PersistenceService.account('a'),
        seedDemo: false,
      );
      await a.initialize();
      final demo = FinancialRepository.demo();
      expect(a.transactions, isEmpty);
      expect(demo.transactions, isNotEmpty);
      a.addTransaction(demo.transactions.first);
      await a.flushPendingWrites();
      expect(
        await PersistenceService.account('a').loadTransactions(),
        hasLength(1),
      );
      expect(await PersistenceService.account('b').loadTransactions(), isEmpty);
      expect(
        await const PersistenceService.local().loadTransactions(),
        isEmpty,
      );
      expect(await const PersistenceService().loadTransactions(), isEmpty);
      await demo.clearAllData();
      expect(
        await PersistenceService.account('a').loadTransactions(),
        hasLength(1),
      );
    },
  );

  test('uma exclusão é desfeita pelo token da ação uma única vez', () {
    final repo = FinancialRepository.demo();
    final transaction = repo.transactions.first;
    final balance = repo.totalBalance;
    repo.deleteTransaction(transaction.id);
    final history = ChatActionHistory.forRepository(repo);
    final deletion = ChatAction(ChatActionKind.deleted, [transaction]);
    history.push(deletion);
    expect(history.undo(repo, only: deletion)?.undone, isTrue);
    expect(
      repo.transactions.where((t) => t.id == transaction.id),
      hasLength(1),
    );
    expect(repo.totalBalance, closeTo(balance, 0.000001));
    expect(history.undo(repo, only: deletion), isNull);
  });

  test('a migração grava apenas as transferências antigas e é idempotente', () async {
    final repo = FinancialRepository.demo();
    final expense = repo.transactions.firstWhere(
      (t) => t.type == TransactionType.expense,
    );
    final legacy = {...expense.toJson(), 'id': 'legacy-transfer', 'type': 'transfer', 'category': 'supermarket'};
    const key = 'krezio_transactions_v1';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode([legacy, expense.toJson()]));
    const persistence = PersistenceService();

    final migrated = await persistence.loadTransactions();
    expect(migrated.map((t) => t.category), ['transfer', expense.category]);
    final stored = prefs.getString(key)!;
    expect((jsonDecode(stored) as List).first['category'], 'transfer');
    await persistence.loadTransactions();
    expect(prefs.getString(key), stored);
  });
}
