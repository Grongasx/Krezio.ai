// Teste do caos, rodada 2 (cesar-chaos) — persistência agrupada.
//
// NÃO falha a suíte: imprime com o prefixo `R2|`.
//   flutter test test/_qa/chaos_r2_persistence_test.dart 2>&1 | grep "R2|"
//
// Gravações agrupadas (`_persistQueued`) intercaladas com `clearAllData`,
// `replaceAllFromCloud` e `initialize` de repositórios novos lendo o mesmo
// SharedPreferences mockado. Depois de `flushPendingWrites`, um "reinício"
// (repositório novo + initialize) tem de ver exatamente o que estava na
// memória: nada perdido, nada ressuscitado. Achados em docs/qa/findings-caos-r2.md.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

String snap(FinancialRepository r) {
  final tx = [for (final t in r.transactions) jsonEncode(t.toJson())]..sort();
  final goals = [for (final g in r.goals) '${g.id}|${g.title}|${g.savedAmount}']..sort();
  final cats = [for (final b in r.budgets) '${b.category}|${b.name}|${b.monthlyLimit}|${b.isCustom}']..sort();
  final ov = (r.categoryOverrides.entries.map((e) => '${e.key}=${e.value}').toList()..sort());
  return jsonEncode({'tx': tx, 'goals': goals, 'cats': cats, 'ov': ov});
}

String diff(String a, String b) {
  final ma = jsonDecode(a) as Map<String, dynamic>, mb = jsonDecode(b) as Map<String, dynamic>;
  final out = <String>[];
  for (final k in ma.keys) {
    final la = (ma[k] as List).cast<String>().toSet(), lb = (mb[k] as List).cast<String>().toSet();
    final lost = la.difference(lb), extra = lb.difference(la);
    String brief(String s) {
      final m = RegExp(r'"(?:id|title)":"([^"]*)"').allMatches(s).map((x) => x.group(1)).join('/');
      return m.isEmpty ? s : m;
    }

    if (lost.isNotEmpty) out.add('$k perdido: ${lost.take(3).map(brief).toList()}${lost.length > 3 ? ' (+${lost.length - 3})' : ''}');
    if (extra.isNotEmpty) out.add('$k a mais: ${extra.take(3).map(brief).toList()}${extra.length > 3 ? ' (+${extra.length - 3})' : ''}');
  }
  return out.join(' ; ');
}

Future<FinancialRepository> restart() async {
  final r = FinancialRepository();
  await r.initialize();
  return r;
}

int _n = 0;
FinancialTransaction tx(String title, double amount) => FinancialTransaction(
      id: 'p-${++_n}',
      title: title,
      amount: amount,
      type: TransactionType.expense,
      category: 'supermarket',
      paymentMethod: 'pix',
      date: DateTime(2026, 9, 20),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> scenario(String name, Future<String> Function() body) async {
    SharedPreferences.setMockInitialValues({});
    String result;
    try {
      result = await body();
    } catch (e) {
      result = 'EXCEÇÃO $e';
    }
    print('R2|PERSIST| $name → $result');
  }

  test('R2 persistência — cenários', () async {
    await scenario('P1 add ⏎ clear (sem await) ⏎ add ⏎ reinício', () async {
      final a = await restart();
      a.addTransaction(tx('Antes', 10));
      final c = a.clearAllData();
      a.addTransaction(tx('Depois', 20));
      await c;
      await a.flushPendingWrites();
      final b = await restart();
      final d = diff(snap(a), snap(b));
      return d.isEmpty ? 'ok' : 'DIFERE: $d';
    });

    await scenario('P2 clear (await) sem nada depois ⏎ reinício', () async {
      final a = await restart();
      await a.clearAllData();
      await a.flushPendingWrites();
      final b = await restart();
      final d = diff(snap(a), snap(b));
      return d.isEmpty ? 'ok' : 'DIFERE (memória vazia, disco após reinício): $d';
    });

    await scenario('P3 clear ⏎ nuvem ⏎ reinício', () async {
      final a = await restart();
      a.addTransaction(tx('Local', 10));
      final c = a.clearAllData();
      a.replaceAllFromCloud(transactions: [tx('Nuvem', 99)], reminders: const [], budgets: const [], goals: const [], categoryOverrides: const {});
      await c;
      await a.flushPendingWrites();
      final b = await restart();
      final d = diff(snap(a), snap(b));
      return d.isEmpty ? 'ok' : 'DIFERE: $d';
    });

    await scenario('P4 nuvem ⏎ clear (sem await) ⏎ add ⏎ reinício', () async {
      final a = await restart();
      a.replaceAllFromCloud(transactions: [tx('Nuvem', 99)], reminders: const [], budgets: const [], goals: const [], categoryOverrides: const {});
      final c = a.clearAllData();
      a.addTransaction(tx('Depois', 5));
      await c;
      await a.flushPendingWrites();
      final b = await restart();
      final d = diff(snap(a), snap(b));
      return d.isEmpty ? 'ok' : 'DIFERE: $d';
    });

    await scenario('P5 mutação durante initialize() de um repositório novo', () async {
      final a = await restart();
      a.addTransaction(tx('Dado antigo', 10));
      await a.flushPendingWrites();
      final b = FinancialRepository();
      final init = b.initialize();
      b.addTransaction(tx('Novo durante init', 20));
      await init;
      await b.flushPendingWrites();
      final c = await restart();
      final hasOld = c.transactions.any((t) => t.title == 'Dado antigo');
      final hasNew = c.transactions.any((t) => t.title == 'Novo durante init');
      final memNew = b.transactions.any((t) => t.title == 'Novo durante init');
      return 'memória tem o novo: $memNew; disco: antigo=$hasOld novo=$hasNew; memória×disco: ${diff(snap(b), snap(c)).isEmpty ? 'iguais' : diff(snap(b), snap(c))}';
    });

    await scenario('P6 replaceAllFromCloud durante initialize() (main.dart roda _loadRepository e _initFirebase em paralelo)', () async {
      final a = await restart();
      a.addTransaction(tx('Local antigo', 10));
      await a.flushPendingWrites();
      final b = FinancialRepository();
      final init = b.initialize();
      b.replaceAllFromCloud(transactions: [tx('Nuvem', 99)], reminders: const [], budgets: const [], goals: const [], categoryOverrides: const {});
      await init;
      await b.flushPendingWrites();
      final c = await restart();
      final mem = b.transactions.map((t) => t.title).toList();
      final disk = c.transactions.map((t) => t.title).toList();
      return 'memória: $mem; disco: $disk';
    });

    for (var k = 0; k <= 12; k++) {
      await scenario('P6b nuvem chega $k microtarefas depois do início de initialize()', () async {
        final a = await restart();
        a.addTransaction(tx('Local antigo', 10));
        await a.flushPendingWrites();
        final b = FinancialRepository();
        final init = b.initialize();
        for (var j = 0; j < k; j++) {
          await Future<void>.microtask(() {});
        }
        b.replaceAllFromCloud(transactions: [tx('Nuvem', 99)], reminders: const [], budgets: const [], goals: const [], categoryOverrides: const {});
        await init;
        await b.flushPendingWrites();
        final c = await restart();
        final mem = b.transactions.map((t) => t.title).toList();
        final disk = c.transactions.map((t) => t.title).toList();
        return 'memória: ${mem.length > 3 ? '${mem.take(3).toList()}…(${mem.length})' : mem}; disco: ${disk.length > 3 ? '${disk.take(3).toList()}…(${disk.length})' : disk}';
      });
    }

    await scenario('P5b o que sobra na memória após mutação durante initialize()', () async {
      final a = await restart();
      await a.clearAllData();
      a.addTransaction(tx('Dado do usuário', 10));
      await a.flushPendingWrites();
      final b = FinancialRepository();
      final init = b.initialize();
      b.addTransaction(tx('Novo durante init', 20));
      await init;
      return 'memória: ${b.transactions.map((t) => t.title).toList()}';
    });

    await scenario('P7 initialize() duas vezes em paralelo (repositórios diferentes) + escrita', () async {
      final a = await restart();
      a.addTransaction(tx('Base', 10));
      await a.flushPendingWrites();
      final b = FinancialRepository();
      final c = FinancialRepository();
      final ib = b.initialize();
      final ic = c.initialize();
      await Future.wait([ib, ic]);
      b.addTransaction(tx('Só em B', 1));
      await b.flushPendingWrites();
      c.addTransaction(tx('Só em C', 2));
      await c.flushPendingWrites();
      final d = await restart();
      return 'disco: ${d.transactions.map((t) => t.title).toList()} (B e C são duas abas/instâncias; última escrita vence)';
    });

    await scenario('P8 rajada de 200 mutações agrupadas ⏎ reinício', () async {
      final a = await restart();
      for (var i = 0; i < 200; i++) {
        a.addTransaction(tx('R$i', 1.0 + i));
        if (i % 3 == 0) a.deleteTransaction('p-${_n - 1}');
      }
      await a.flushPendingWrites();
      final b = await restart();
      final d = diff(snap(a), snap(b));
      return d.isEmpty ? 'ok' : 'DIFERE: $d';
    });
  });

  test('R2 persistência — fuzz', () async {
    final sw = Stopwatch()..start();
    var ops = 0, checkpoints = 0;
    final problems = <String, List<String>>{};
    for (final seed in [20260924, 7, 99, 2027]) {
      SharedPreferences.setMockInitialValues({});
      final rng = Random(seed);
      var a = await restart();
      final log = <String>[];
      Future<void>? pendingClear;
      var clearedWithoutWrite = false;
      for (var i = 0; i < 400; i++) {
        ops++;
        final r = rng.nextInt(100);
        if (r < 30) {
          a.addTransaction(tx('F$i', 1.0 + rng.nextInt(500)));
          log.add('add');
          clearedWithoutWrite = false;
        } else if (r < 42 && a.transactions.isNotEmpty) {
          final t = a.transactions[rng.nextInt(a.transactions.length)];
          a.deleteTransaction(t.id);
          log.add('del');
          clearedWithoutWrite = false;
        } else if (r < 52 && a.transactions.isNotEmpty) {
          final t = a.transactions[rng.nextInt(a.transactions.length)];
          a.updateTransaction(t.copyWith(amount: 2.0 + rng.nextInt(300)));
          log.add('upd');
          clearedWithoutWrite = false;
        } else if (r < 58) {
          a.addGoal(FinancialGoal(id: 'g$i', title: 'Meta $i', targetAmount: 1000));
          log.add('goal');
          clearedWithoutWrite = false;
        } else if (r < 63 && a.goals.isNotEmpty) {
          a.contributeToGoal(a.goals.first.id, 10);
          log.add('contrib');
          clearedWithoutWrite = false;
        } else if (r < 68) {
          a.addBudgetCategory('Cat ${rng.nextInt(5)}', rng.nextInt(400).toDouble());
          log.add('cat');
          clearedWithoutWrite = false;
        } else if (r < 71) {
          final custom = a.budgets.where((b) => b.isCustom).toList();
          if (custom.isNotEmpty) a.removeBudgetCategory(custom.first.category);
          log.add('rmcat');
          clearedWithoutWrite = false;
        } else if (r < 74) {
          a.rememberCategoryOverride('item ${rng.nextInt(4)}', 'leisure');
          log.add('override');
          clearedWithoutWrite = false;
        } else if (r < 79) {
          if (rng.nextBool()) {
            await a.clearAllData();
            log.add('clear(await)');
          } else {
            pendingClear = a.clearAllData();
            log.add('clear');
          }
          clearedWithoutWrite = true;
        } else if (r < 84) {
          final keep = a.transactions.where((_) => rng.nextBool()).toList();
          a.replaceAllFromCloud(
            transactions: [...keep, tx('Nuvem$i', 42)],
            reminders: a.reminders,
            budgets: a.budgets,
            goals: a.goals,
            categoryOverrides: a.categoryOverrides,
          );
          log.add('cloud');
          clearedWithoutWrite = false;
        } else if (r < 92) {
          await Future<void>.delayed(Duration.zero);
          log.add('yield');
        } else {
          // Ponto de verificação: reinício com repositório novo.
          if (pendingClear != null) await pendingClear;
          await a.flushPendingWrites();
          checkpoints++;
          final b = await restart();
          final d = diff(snap(a), snap(b));
          if (d.isNotEmpty) {
            final kind = clearedWithoutWrite ? 'seed_volta_apos_limpar' : 'perdido_ou_ressuscitado';
            problems.putIfAbsent(kind, () => []).add('seed=$seed op=$i últimas=${log.skip(max(0, log.length - 6)).join(',')} → $d');
          }
          // Continua a partir do repositório reiniciado (como o app faria).
          a = b;
          log.add('RESTART');
          clearedWithoutWrite = false;
        }
      }
    }
    print('R2|PERSIST| fuzz: $ops operações, $checkpoints reinícios, ${sw.elapsedMilliseconds} ms');
    if (problems.isEmpty) print('R2|PERSIST| fuzz: nenhuma perda/ressurreição');
    problems.forEach((k, v) {
      print('R2|PERSIST| fuzz $k: ${v.length} ocorrência(s); primeira: ${v.first}');
    });
  });
}
