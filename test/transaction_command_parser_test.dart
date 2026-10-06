import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/chat_action_history.dart';
import 'package:krezio_ai/ai/transaction_command_parser.dart';
import 'package:krezio_ai/ai/transaction_reference_resolver.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final budgets = FinancialRepository().budgets;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  ChatCommand? parse(String s) => TransactionCommandParser.parse(s, now: now, budgets: budgets);

  group('TransactionCommandParser — edição', () {
    test('valor em várias formas', () {
      for (final p in ['não, foi 45', 'nao foi 45', 'ops, era 45', 'corrige pra 45', 'o valor certo é 45', 'na verdade foi 45', 'muda pra 45', 'era quarenta e cinco']) {
        final c = parse(p);
        expect(c?.kind, ChatCommandKind.edit, reason: p);
        expect(c!.changes.amount, 45, reason: p);
        expect(c.reference, '', reason: p);
      }
    });

    test('negação: "não foi 50, foi 45" fica com 45', () {
      expect(parse('não foi 50, foi 45')!.changes.amount, 45);
    });

    test('data, tipo, categoria, pagamento, parcelas', () {
      expect(parse('na verdade foi ontem')!.changes.date, today.subtract(const Duration(days: 1)));
      expect(parse('foi anteontem')!.changes.date, today.subtract(const Duration(days: 2)));
      expect(parse('na verdade foi uma entrada')!.changes.type, TransactionType.income);
      expect(parse('era receita, não gasto')!.changes.type, TransactionType.income);
      expect(parse('era transferência')!.changes.type, TransactionType.transfer);
      expect(parse('esse era lazer')!.changes.category, 'leisure');
      expect(parse('coloca em lazer')!.changes.category, 'leisure');
      expect(parse('na verdade foi farmácia')!.changes.category, 'health');
      expect(parse('não é mercado, é farmácia')!.changes.category, 'health');
      expect(parse('e foi no débito')!.changes.paymentMethod, 'debit_card');
      expect(parse('isso foi no crédito')!.changes.paymentMethod, 'credit_card');
      final inst = parse('na verdade foi no crédito em 3x')!.changes;
      expect(inst.paymentMethod, 'credit_card');
      expect(inst.installments, 3);
      expect(inst.amount, isNull, reason: '3x não é valor');
    });

    test('"foi dia 10" é data, não valor', () {
      final c = parse('foi dia 10')!.changes;
      expect(c.amount, isNull);
      expect(c.date!.day, 10);
    });

    test('referência + campo: "muda o valor do aluguel pra 1500"', () {
      final c = parse('muda o valor do aluguel pra 1500')!;
      expect(c.reference, 'aluguel');
      expect(c.changes.amount, 1500);
      expect(c.changes.category, isNull);
    });

    test('renomear: "renomeia o último para Padaria" guarda a grafia', () {
      final c = parse('renomeia o último para Padaria')!;
      expect(c.changes.title, 'Padaria');
      expect(c.reference, 'o ultimo');
    });

    test('sem verbo, só com data: "o mercado de ontem foi no débito"', () {
      final c = parse('o mercado de ontem foi no débito')!;
      expect(c.strong, isFalse);
      expect(c.reference, contains('mercado'));
      expect(c.changes.paymentMethod, 'debit_card');
    });

    test('"edita o último lançamento" pede o que mudar', () {
      expect(parse('edita o último lançamento')!.kind, ChatCommandKind.showForEdit);
    });
  });

  group('TransactionCommandParser — exclusão e desfazer', () {
    test('verbos de exclusão com e sem referência', () {
      for (final p in ['exclui o uber', 'apaga o aluguel', 'apaga o anterior', 'apaga os dois últimos', 'exclui o uber de ontem', 'deleta', 'cancela',
        'exclui esse lançamento', 'remove a assinatura da netflix', 'pode apagar o último?', 'desconsidera esse']) {
        expect(parse(p)?.kind, ChatCommandKind.delete, reason: p);
      }
    });

    test('desfazer', () {
      for (final p in ['desfaz', 'desfazer', 'volta atrás', 'desfaz o que você fez', 'não era pra apagar, volta', 'ctrl z']) {
        expect(TransactionCommandParser.isUndo(p), isTrue, reason: p);
      }
      for (final p in ['não desfaz', 'gastei 50 no mercado', 'volta pra casa custou 30']) {
        expect(TransactionCommandParser.isUndo(p), isFalse, reason: p);
      }
    });
  });

  group('não dispara em lançamentos normais nem em outros assuntos', () {
    for (final p in [
      'apaguei a luz e gastei 50',
      'gastei 50 no mercado',
      'o mercado de ontem estava cheio, gastei 80',
      'o almoço de ontem foi 45',
      'e 30 na padaria',
      'mais 20 de gorjeta',
      'tira 50 da meta',
      'apaga a categoria pets',
      'renomeia a categoria pets para animais',
      'coloca 100 na meta da viagem',
      'muda o limite de lazer pra 800',
      'quanto gastei?',
      'isso mesmo',
      'foi ótimo o dia hoje',
      'desconsidera o valor, foi no débito',
    ]) {
      test(p, () {
        final c = parse(p);
        // "desconsidera o valor, foi no débito" is not a delete; the rest are nothing.
        expect(c == null || c.kind != ChatCommandKind.delete, isTrue, reason: '$c');
        if (p != 'desconsidera o valor, foi no débito' && p != 'foi ótimo o dia hoje') expect(c, isNull, reason: '$c');
      });
    }
  });

  group('TransactionReferenceResolver', () {
    FinancialTransaction t(String id, String title, double amount, DateTime date, [String cat = 'transport']) =>
        FinancialTransaction(id: id, title: title, amount: amount, type: TransactionType.expense, category: cat, paymentMethod: 'pix', date: date);
    final all = [
      t('1', 'Uber', 30, today.subtract(const Duration(days: 1))),
      t('2', 'Uber', 25, today),
      t('3', 'Aluguel do Apartamento', 1400, today.subtract(const Duration(days: 10)), 'housing'),
      t('4', 'Farmácia', 80, today, 'health'),
    ];
    List<String> ids(String ref, {List<List<String>> groups = const []}) => TransactionReferenceResolver.resolve(
          TransactionReferenceResolver.parse(ref, now: now),
          all: all,
          recentGroups: groups,
          budgets: budgets,
        ).matches.map((t) => t.id).toList();

    test('por descrição, data e valor', () {
      expect(ids('o uber'), ['2', '1']);
      expect(ids('o uber de ontem'), ['1']);
      expect(ids('o de 1400'), ['3']);
      expect(ids('o aluguel'), ['3']);
    });

    test('por categoria em português', () {
      expect(ids('o de saúde'), ['4']);
    });

    test('por posição, usando o que o chat criou', () {
      final groups = [['3'], ['4']];
      expect(ids('o último', groups: groups), ['4']);
      expect(ids('o anterior', groups: groups), ['3']);
      expect(ids('os dois últimos', groups: groups), unorderedEquals(['3', '4']));
    });

    test('nada encontrado traz sugestões', () {
      final r = TransactionReferenceResolver.resolve(TransactionReferenceResolver.parse('o uber de anteontem', now: now),
          all: all, recentGroups: const [], budgets: budgets);
      expect(r.matches, isEmpty);
      expect(r.suggestions.map((t) => t.id), containsAll(['1', '2']));
    });
  });

  group('ChatActionHistory', () {
    test('desfaz criação, edição e exclusão em ordem', () async {
      final repo = FinancialRepository();
      await repo.clearAllData();
      final a = FinancialTransaction(id: 'a', title: 'A', amount: 10, type: TransactionType.expense, category: 'leisure', paymentMethod: 'pix', date: today);
      repo.addTransaction(a);
      final h = ChatActionHistory()..push(ChatAction(ChatActionKind.created, [a]));
      repo.updateTransaction(a.copyWith(amount: 20));
      h.push(ChatAction(ChatActionKind.edited, [a]));
      final edited = repo.transactions.single;
      repo.deleteTransaction('a');
      h.push(ChatAction(ChatActionKind.deleted, [edited]));

      expect(h.undo(repo)!.action.kind, ChatActionKind.deleted);
      expect(repo.transactions.single.amount, 20);
      expect(h.undo(repo)!.action.kind, ChatActionKind.edited);
      expect(repo.transactions.single.amount, 10);
      expect(h.undo(repo)!.action.kind, ChatActionKind.created);
      expect(repo.transactions, isEmpty);
      expect(h.undo(repo), isNull);
    });
  });
}
