// Rodada 3 do corretor: achados do caos (R2-CHAOS-007…026) no CesarAssistant,
// no desfazer e no resolvedor de referências. Cenários e frases diferentes dos
// relatórios, para mostrar que a regra generalizou.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/chat_action_history.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/ai/transaction_reference_resolver.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalFinancialNlpEngine engine;

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  Future<(FinancialRepository, CesarAssistant)> fresh({DateTime? now, List<FinancialTransaction> seed = const []}) async {
    SharedPreferences.setMockInitialValues({});
    final repo = FinancialRepository();
    await repo.clearAllData();
    for (final t in seed) {
      repo.addTransaction(t);
    }
    return (repo, CesarAssistant(repository: repo, engine: engine, now: now == null ? null : () => now));
  }

  /// Same order as the chat: commands (with rewrite) → questions → new entry.
  AssistantReply? say(FinancialRepository repo, CesarAssistant a, String t, {bool pendingDraft = false}) {
    a.beginTurn();
    var text = t;
    final cmd = a.handleCommand(text, hasPendingDraft: pendingDraft);
    if (cmd != null && cmd.rewrittenInput == null) return cmd;
    if (pendingDraft) return cmd;
    if (cmd != null) text = cmd.rewrittenInput!;
    final q = cmd == null ? a.handleQuestion(text) : null;
    if (q != null) return q;
    final d = engine.parse(text);
    if (LocalFinancialNlpEngine.isRecordable(d)) a.recordCreated(repo.addTransactionFromDraft(d).map((t) => t.id).toList());
    return cmd;
  }

  FinancialTransaction tx(String id, String title, double amount, DateTime date, {String category = 'supermarket'}) =>
      FinancialTransaction(id: id, title: title, amount: amount, type: TransactionType.expense, category: category, paymentMethod: 'pix', date: date);

  group('R2-CHAOS-007: "cria a categoria X com limite" com X já existente muda o limite, e o desfaz volta o limite', () {
    for (final e in {'Pets': 'cria a categoria pets com limite de 300', 'Academia Extra': 'criar categoria academia extra com limite de 90'}.entries) {
      test(e.value, () async {
        final (repo, a) = await fresh();
        repo.addBudgetCategory(e.key, 200);
        final r = say(repo, a, e.value)!;
        expect(r.route, 'budget_set');
        expect(r.text, contains('já existia'));
        final undo = say(repo, a, 'desfaz')!;
        expect(undo.route, 'undo');
        final b = repo.budgets.firstWhere((b) => b.name == e.key);
        expect(b.monthlyLimit, 200);
      });
    }
  });

  group('R2-CHAOS-008/023: desfazer algo que sumiu fora do chat avisa e não quebra', () {
    test('aporte em meta apagada depois', () async {
      final (repo, a) = await fresh();
      repo.addGoal(FinancialGoal(id: 'g-carro', title: 'Carro', targetAmount: 30000));
      expect(say(repo, a, 'guardei 250 na meta do carro')!.route, 'goal_contrib');
      repo.deleteGoal('g-carro');
      final r = say(repo, a, 'desfaz')!;
      expect(r.route, 'undo_failed');
      expect(repo.goals, isEmpty);
    });

    test('retirada de meta apagada pelo "Limpar Histórico" não lança exceção', () async {
      final (repo, a) = await fresh();
      repo.addGoal(FinancialGoal(id: 'g-casa', title: 'Casa', targetAmount: 90000, savedAmount: 500));
      expect(say(repo, a, 'tira 100 da meta da casa')!.route, 'goal_withdraw');
      repo.deleteGoal('g-casa');
      expect(() => say(repo, a, 'desfaz'), returnsNormally);
    });

    test('limite de categoria apagada fora do chat', () async {
      final (repo, a) = await fresh();
      final b = repo.addBudgetCategory('Jardim', 120);
      say(repo, a, 'meu limite de jardim é 150');
      repo.removeBudgetCategory(b.category);
      final r = say(repo, a, 'desfaz')!;
      expect(r.route, 'undo_failed');
      expect(r.text, isNot(contains('voltou')));
    });

    test('renomear e ver o nome antigo ocupado fora do chat', () async {
      final (repo, a) = await fresh();
      repo.addBudgetCategory('Bichos', 100);
      say(repo, a, 'renomeia a categoria bichos para animais');
      repo.addBudgetCategory('Bichos', 50);
      final r = say(repo, a, 'desfaz')!;
      expect(r.route, 'undo_failed');
    });
  });

  group('R2-CHAOS-009/025: data que não existe não vira outro dia', () {
    final oct1 = DateTime(2026, 10, 1, 10);
    for (final p in ['muda o mercado do dia 31 pra 99', 'apaga o mercado do dia 0', 'apaga o mercado de 45/13', 'muda o de 31/09 pra 20', 'apaga o de 30/02']) {
      test(p, () async {
        final (repo, a) = await fresh(now: oct1, seed: [tx('m-hoje', 'Mercado', 40, oct1)]);
        final r = say(repo, a, p)!;
        expect(r.route, 'invalid_date', reason: r.text);
        expect(repo.transactions.single.amount, 40);
      });
    }

    test('dia que existe no mês anterior continua funcionando', () async {
      final (repo, a) = await fresh(now: oct1, seed: [tx('m-30', 'Mercado', 40, DateTime(2026, 9, 30, 9))]);
      expect(say(repo, a, 'apaga o mercado do dia 30')!.route, 'confirm_delete');
    });
  });

  group('R2-CHAOS-015/016: valor com milhar e data do ano anterior', () {
    test('"o de 1.400", "de R\$ 2.350,90" acham o lançamento', () {
      final now = DateTime(2026, 9, 24);
      expect(TransactionReferenceResolver.parse('o de 1.400', now: now).amount, 1400);
      expect(TransactionReferenceResolver.parse('apaga o de R\$ 2.350,90', now: now).amount, 2350.90);
      expect(TransactionReferenceResolver.parse('o de 12.000', now: now).amount, 12000);
      expect(TransactionReferenceResolver.parse('o de 48,90', now: now).amount, 48.90);
    });

    test('"31/12" no dia 1º de janeiro é do ano passado; "15/11" em março também', () {
      expect(TransactionReferenceResolver.parse('o de 31/12', now: DateTime(2027, 1, 1)).dayStart, DateTime(2026, 12, 31));
      expect(TransactionReferenceResolver.parse('o de 15/11', now: DateTime(2027, 3, 2)).dayStart, DateTime(2026, 11, 15));
      expect(TransactionReferenceResolver.parse('o de 02/03', now: DateTime(2027, 3, 2)).dayStart, DateTime(2027, 3, 2));
    });

    test('apagar o aluguel de 1.400 pelo chat', () async {
      final (repo, a) = await fresh(seed: [tx('al', 'Aluguel', 1400, DateTime.now(), category: 'housing')]);
      expect(say(repo, a, 'apaga o de R\$ 1.400,00')!.route, 'confirm_delete');
    });
  });

  group('R2-CHAOS-012: "Limpar Histórico" zera o que a conversa lembra', () {
    test('desfazer depois da limpeza não traz nada de volta', () async {
      final (repo, a) = await fresh();
      say(repo, a, 'gastei 70 na farmácia no pix');
      say(repo, a, 'apaga o último');
      say(repo, a, 'sim');
      say(repo, a, 'paguei 30 no estacionamento no pix');
      await repo.clearAllData();
      final r = say(repo, a, 'desfaz')!;
      expect(r.route, 'undo_empty');
      expect(repo.transactions, isEmpty);
    });

    test('dados trocados pela nuvem também zeram', () async {
      final (repo, a) = await fresh();
      say(repo, a, 'gastei 45 no açougue no pix');
      repo.replaceAllFromCloud(transactions: const [], reminders: const [], budgets: const [], goals: const [], categoryOverrides: const {});
      expect(say(repo, a, 'muda pra 50')!.route, 'ask_target');
    });
  });

  group('R2-CHAOS-013: aporte em meta com rascunho pendente entra no desfazer', () {
    test('o desfaz tira o aporte, e não apaga o lançamento anterior', () async {
      final (repo, a) = await fresh();
      repo.addGoal(FinancialGoal(id: 'g-moto', title: 'Moto', targetAmount: 12000));
      say(repo, a, 'gastei 80 no posto no pix');
      final contrib = say(repo, a, 'guardei 300 na meta da moto', pendingDraft: true)!;
      expect(contrib.route, 'goal_contrib');
      final r = say(repo, a, 'desfaz')!;
      expect(r.route, 'undo');
      expect(repo.goals.single.savedAmount, 0);
      expect(repo.transactions.single.amount, 80);
    });
  });

  group('R2-CHAOS-014/024: desfazer para no que não dá, e diz o limite de 20', () {
    test('lançamento editado apagado fora do chat: avisa e não desfaz o anterior', () async {
      final (repo, a) = await fresh();
      say(repo, a, 'gastei 60 no açougue no pix');
      say(repo, a, 'gastei 25 na farmácia no pix');
      final farmacia = repo.transactions.firstWhere((t) => t.amount == 25);
      expect(say(repo, a, 'muda pra 28')!.route, 'edited');
      repo.deleteTransaction(farmacia.id);
      final r = say(repo, a, 'desfaz')!;
      expect(r.route, 'undo_failed');
      expect(repo.transactions.single.amount, 60);
    });

    test('lançamento criado e já apagado fora do chat: avisa', () async {
      final (repo, a) = await fresh();
      say(repo, a, 'gastei 33 na padaria no pix');
      say(repo, a, 'gastei 18 no uber no pix');
      final last = repo.transactions.first;
      repo.deleteTransaction(last.id);
      final r = say(repo, a, 'desfaz')!;
      expect(r.route, 'undo_failed');
      expect(repo.transactions.length, 1);
    });

    test('mais de 20 ações: diz que o limite é 20', () async {
      final (repo, a) = await fresh();
      for (var i = 0; i < 23; i++) {
        say(repo, a, 'gastei ${10 + i} no mercado no pix');
      }
      for (var i = 0; i < ChatActionHistory.maxActions; i++) {
        expect(say(repo, a, 'desfaz')!.route, 'undo');
      }
      final r = say(repo, a, 'desfaz')!;
      expect(r.route, 'undo_limit');
      expect(r.text, contains('20'));
      expect(repo.transactions.length, 3);
    });
  });

  group('R2-CHAOS-017/026: escolha da lista não se perde', () {
    Future<(FinancialRepository, CesarAssistant)> threeOf(double v) async {
      final now = DateTime.now();
      return fresh(seed: [
        tx('a', 'Açougue', v, now),
        tx('b', 'Farmácia', v, now.subtract(const Duration(days: 1)), category: 'health'),
        tx('c', 'Posto', v, now.subtract(const Duration(days: 2)), category: 'transport'),
      ]);
    }

    test('número fora da lista pergunta de novo', () async {
      final (repo, a) = await threeOf(35);
      expect(say(repo, a, 'apaga o de 35')!.route, 'choose');
      for (final n in ['4', '7', 'o 9']) {
        final r = say(repo, a, n)!;
        expect(r.route, 'choose', reason: n);
        expect(r.text, contains('Só há 3'));
      }
      expect(say(repo, a, '2')!.route, 'confirm_delete');
    });

    test('referência que ainda combina com vários pergunta de novo, sem virar lançamento', () async {
      final (repo, a) = await threeOf(35);
      say(repo, a, 'muda o de 35 pra 40');
      final r = say(repo, a, 'o de 35')!;
      expect(r.route, 'choose');
      expect(repo.transactions.length, 3);
      expect(say(repo, a, 'o da farmácia')!.route, 'edited');
      expect(repo.transactions.firstWhere((t) => t.id == 'b').amount, 40);
    });

    test('frase nova larga a lista', () async {
      final (repo, a) = await threeOf(35);
      say(repo, a, 'apaga o de 35');
      expect(say(repo, a, 'gastei 12 na banca de jornal no pix'), isNull);
    });
  });

  group('R2-CHAOS-018: "esse" apagado não cai no lançamento anterior', () {
    for (final follow in ['muda pra 80', 'muda pra débito', 'na verdade foi 15']) {
      test(follow, () async {
        final (repo, a) = await fresh();
        say(repo, a, 'gastei 90 no açougue no pix');
        say(repo, a, 'gastei 14 no uber no pix');
        say(repo, a, 'apaga esse');
        say(repo, a, 'sim');
        final r = say(repo, a, follow);
        expect(r?.route, 'ask_target', reason: r?.text);
        expect(repo.transactions.single.amount, 90);
        expect(repo.transactions.single.paymentMethod, 'pix');
      });
    }
  });
}
