import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/cloud_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

FinancialTransaction tx(String id, String title, double amount) => FinancialTransaction(
      id: id,
      title: title,
      amount: amount,
      type: TransactionType.expense,
      category: 'supermarket',
      paymentMethod: 'pix',
      date: DateTime(2026, 9, 20),
    );

/// Each device has its own storage for the sync base.
class MemoryStore implements SyncBaseStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
}

/// A "device": its own repository and storage, sharing the same (fake) Firestore.
Future<(FinancialRepository, CloudSyncService)> device(FakeFirebaseFirestore db,
    {List<FinancialTransaction> start = const [], MemoryStore? store}) async {
  final repo = FinancialRepository();
  repo.replaceAllFromCloud(transactions: start, reminders: [], budgets: repo.budgets.toList(), goals: [], categoryOverrides: {});
  return (repo, CloudSyncService(repository: repo, uid: 'u1', firestore: db, baseStore: store ?? MemoryStore()));
}

Map<String, double> amounts(FinancialRepository r) => {for (final t in r.transactions) t.id: t.amount};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('primeira sincronização envia o que está no aparelho', () async {
    final db = FakeFirebaseFirestore();
    final (a, sa) = await device(db, start: [tx('1', 'Mercado', 50)]);
    await sa.sync();
    final doc = await db.collection('users').doc('u1').get();
    expect((doc.data()!['transactions'] as List).length, 1);
    expect(amounts(a), {'1': 50});
  });

  test('outro aparelho baixa os dados da conta', () async {
    final db = FakeFirebaseFirestore();
    final (_, sa) = await device(db, start: [tx('1', 'Mercado', 50)]);
    await sa.sync();
    final (b, sb) = await device(db);
    await sb.sync();
    expect(amounts(b), {'1': 50});
  });

  test('dois aparelhos editando ao mesmo tempo: nenhuma edição some', () async {
    final db = FakeFirebaseFirestore();
    final (a, sa) = await device(db, start: [tx('1', 'Mercado', 50), tx('2', 'Padaria', 10)]);
    await sa.sync();
    final (b, sb) = await device(db);
    await sb.sync();

    // Offline nos dois: A muda o Mercado, B muda a Padaria e cria o Uber.
    a.updateTransaction(tx('1', 'Mercado', 55));
    b.updateTransaction(tx('2', 'Padaria', 12));
    b.addTransaction(tx('3', 'Uber', 30));

    await sa.sync();
    await sb.sync(); // antes: B gravava por cima e o 55 do A sumia
    await sa.sync();

    expect(amounts(a), {'1': 55, '2': 12, '3': 30});
    expect(amounts(b), {'1': 55, '2': 12, '3': 30});
  });

  test('apagar num aparelho apaga no outro', () async {
    final db = FakeFirebaseFirestore();
    final (a, sa) = await device(db, start: [tx('1', 'Mercado', 50), tx('2', 'Padaria', 10)]);
    await sa.sync();
    final (b, sb) = await device(db);
    await sb.sync();

    a.deleteTransaction('2');
    await sa.sync();
    await sb.sync();
    expect(amounts(b), {'1': 50});
  });

  test('a base sobrevive ao reinício do app (exclusão offline não ressuscita)', () async {
    final db = FakeFirebaseFirestore();
    final store = MemoryStore();
    final (a, sa) = await device(db, start: [tx('1', 'Mercado', 50), tx('2', 'Padaria', 10)], store: store);
    await sa.sync();

    // "Reinicia" o app: serviço novo, mesmo aparelho (mesmo armazenamento).
    a.deleteTransaction('2');
    final sa2 = CloudSyncService(repository: a, uid: 'u1', firestore: db, baseStore: store);
    await sa2.sync();
    expect(amounts(a), {'1': 50}, reason: 'sem a base salva, a Padaria voltaria da nuvem');
  });

  test('sincronizar sem mudanças não regrava a nuvem', () async {
    final db = FakeFirebaseFirestore();
    final (_, sa) = await device(db, start: [tx('1', 'Mercado', 50)]);
    await sa.sync();
    final first = (await db.collection('users').doc('u1').get()).data()!['updatedAt'];
    await sa.sync();
    final second = (await db.collection('users').doc('u1').get()).data()!['updatedAt'];
    expect(second, first);
  });
}
