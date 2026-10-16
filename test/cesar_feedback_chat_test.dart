import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/chat_draft_tracker.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/ai/record_lookup.dart';
import 'package:krezio_ai/ai/transaction_code.dart';
import 'package:krezio_ai/ai/transaction_command_parser.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

/// Feedback do usuário (2026-10-16): código do card, vários ajustes num texto,
/// lembrar/editar/apagar lançamentos já finalizados e chips presos ao card.
class Chat {
  final LocalFinancialNlpEngine engine;
  final FinancialRepository repo;
  final CesarAssistant assistant;
  Chat(this.engine, this.repo) : assistant = CesarAssistant(repository: repo, engine: engine);

  AssistantReply? send(String input) {
    var text = input;
    assistant.beginTurn();
    final cmd = assistant.handleCommand(text);
    if (cmd != null && cmd.rewrittenInput == null) return cmd;
    if (cmd != null) text = cmd.rewrittenInput!;
    final q = assistant.handleQuestion(text);
    if (q != null) return q;
    final draft = engine.parse(text);
    if (LocalFinancialNlpEngine.isRecordable(draft)) {
      assistant.recordCreated(repo.addTransactionFromDraft(draft).map((t) => t.id).toList());
    }
    return null;
  }

  FinancialTransaction byTitle(String t) => repo.transactions.firstWhere((x) => x.title.toLowerCase() == t);
}

FinancialTransaction tx(String id, String title, double amount, DateTime date, {String pay = 'pix', String cat = 'supermarket'}) =>
    FinancialTransaction(id: id, title: title, amount: amount, type: TransactionType.expense, category: cat, paymentMethod: pay, date: date);

void main() {
  late LocalFinancialNlpEngine engine;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 10);

  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  Chat fresh(List<FinancialTransaction> seed) {
    final repo = FinancialRepository();
    repo.replaceAllFromCloud(transactions: seed, reminders: [], budgets: repo.budgets.toList(), goals: [], categoryOverrides: {});
    return Chat(engine, repo);
  }

  group('código do card (#4821)', () {
    test('código curto do id e reconhecimento na frase', () {
      expect(TransactionCode.of('1792124660112'), '0112');
      expect(TransactionCode.label('1792124660112'), '#0112');
      expect(TransactionCode.of('init-3'), '3');
      for (final s in ['apaga o #0112', 'o # 0112 foi 50', 'muda o lançamento 0112 pra 30', 'id 0112', 'código 0112']) {
        expect(TransactionCode.find(s), '0112', reason: s);
      }
      expect(TransactionCode.find('gastei 50 no mercado'), isNull);
      expect(TransactionCode.find('apaga o lançamento de 80'), isNull, reason: '"de 80" é valor, não código');
      expect(TransactionCode.matches('1792124660112', '#0112'), isTrue);
      expect(TransactionCode.matches('1792124660112', '1792124660112'), isTrue);
    });

    test('apagar, editar e lembrar pelo código', () {
      final c = fresh([tx('1700000004821', 'Mercado', 50, today), tx('1700000009999', 'Mercado', 70, today)]);
      expect(c.send('apaga o #4821')!.text, contains('R\$ 50,00'));
      expect(c.send('sim')!.route, 'deleted');
      expect(c.repo.transactions.map((t) => t.id), ['1700000009999']);

      expect(c.send('muda o #9999 pra 75')!.route, 'edited');
      expect(c.repo.transactions.single.amount, 75);

      final r = c.send('me mostra o #9999')!;
      expect(r.route, 'lookup');
      expect(r.text, contains('#9999'));
    });
  });

  group('vários ajustes num texto', () {
    test('campos rotulados (com vírgula, dois-pontos ou "e")', () {
      final p = TransactionCommandParser.parse('muda a pizzaria: valor 95, pagamento débito, categoria lazer', now: now, budgets: FinancialRepository().budgets)!;
      expect(p.reference, contains('pizzaria'));
      expect(p.changes.amount, 95);
      expect(p.changes.paymentMethod, 'debit_card');
      expect(p.changes.category, 'leisure');
      expect(p.changes.title, isNull, reason: 'o nome não pode virar "Pizzaria pagamento lazer"');

      final q = TransactionCommandParser.parse('muda o valor pra 120 e o pagamento pra crédito', now: now, budgets: FinancialRepository().budgets)!;
      expect(q.reference, isEmpty, reason: 'sem nome: o último lançamento');
      expect(q.changes.amount, 120);
      expect(q.changes.paymentMethod, 'credit_card');
    });

    test('aplica todos os ajustes no lançamento certo', () {
      final c = fresh([tx('1700000001111', 'Pizzaria', 80, today, cat: 'leisure')]);
      c.assistant.recordCreated(['1700000001111']);
      final r = c.send('troca a pizzaria: valor 95, pagamento débito, data ontem')!;
      expect(r.route, 'edited');
      final t = c.repo.transactions.single;
      expect(t.amount, 95);
      expect(t.paymentMethod, 'debit_card');
      expect(t.date.day, today.subtract(const Duration(days: 1)).day);
      expect(t.title, 'Pizzaria');
    });

    test('um ajuste diferente para cada lançamento, num "desfaz" só', () {
      final c = fresh([tx('1700000001111', 'Padaria', 30, today), tx('1700000002222', 'Uber', 40, today, cat: 'transport')]);
      final r = c.send('muda o uber pra 45 e a padaria pra 35')!;
      expect(r.route, 'edited');
      expect(c.byTitle('uber').amount, 45);
      expect(c.byTitle('padaria').amount, 35);
      c.send('desfaz');
      expect(c.byTitle('uber').amount, 40);
      expect(c.byTitle('padaria').amount, 30);
    });

    test('com "Uber" e "Uber Viagens", "o uber" é o de nome exato', () {
      final c = fresh([tx('1700000002222', 'Uber', 40, today, cat: 'transport'), tx('1700000003333', 'Uber Viagens', 48, today.subtract(const Duration(days: 2)), cat: 'transport')]);
      expect(c.send('muda o uber pra 45')!.route, 'edited');
      expect(c.byTitle('uber').amount, 45);
      expect(c.byTitle('uber viagens').amount, 48);
    });

    test('"a pizzaria" acha o lançamento chamado "Pizza" (mesma raiz)', () {
      final c = fresh([tx('1700000001111', 'Pizza', 80, today, cat: 'leisure')]);
      expect(c.send('muda a pizzaria pra 90')!.route, 'edited');
      expect(c.repo.transactions.single.amount, 90);
    });
  });

  group('lembrar um lançamento já finalizado', () {
    test('perguntas sobre UM lançamento × perguntas de total', () {
      for (final s in [
        'qual foi o valor do restaurante?',
        'quanto foi o restaurante?',
        'quanto deu o uber de ontem?',
        'quando foi a farmácia?',
        'como paguei o mercado?',
        'lembra do restaurante?',
        'você lembra da padaria de ontem?',
        'me mostra o aluguel',
        'o que foi o #4821?',
      ]) {
        expect(RecordLookupParser.parse(s), isNotNull, reason: s);
      }
      for (final s in [
        'quanto gastei com restaurante?',
        'quanto gastei esse mês?',
        'qual meu maior gasto?',
        'me mostra os gastos de hoje',
        'quando vence a luz?',
      ]) {
        expect(RecordLookupParser.parse(s), isNull, reason: s);
      }
    });

    test('mostra o lançamento com o código e deixa em foco para a próxima frase', () {
      final c = fresh([tx('1700000005555', 'Restaurante', 120, today, pay: 'credit_card', cat: 'food')]);
      final r = c.send('qual foi o valor do restaurante?')!;
      expect(r.route, 'lookup');
      expect(r.text, contains('R\$ 120,00'));
      expect(r.text, contains('#5555'));
      expect(c.send('foi 130')!.route, 'edited');
      expect(c.repo.transactions.single.amount, 130);
    });

    test('pergunta e correção na mesma frase', () {
      final c = fresh([tx('1700000005555', 'Restaurante', 120, today, pay: 'credit_card', cat: 'food')]);
      expect(c.send('lembra do restaurante? foi 130')!.route, 'edited');
      expect(c.repo.transactions.single.amount, 130);
    });

    test('dois iguais: lista com os códigos para escolher', () {
      final c = fresh([tx('1700000001111', 'Mercado', 50, today), tx('1700000002222', 'Mercado', 70, today)]);
      final r = c.send('quanto foi o mercado?')!;
      expect(r.route, 'lookup_many');
      expect(r.text, allOf(contains('#1111'), contains('#2222')));
    });

    test('apagar pelo que foi dito: item, data e valor', () {
      final c = fresh([tx('1700000001111', 'Padaria', 30, today), tx('1700000002222', 'Mercado', 60, today)]);
      expect(c.send('apaga a padaria de hoje')!.text, contains('Padaria'));
      expect(c.send('sim')!.route, 'deleted');
      final d = fresh([tx('1700000001111', 'Pizza', 80, today.subtract(const Duration(days: 1)), cat: 'leisure')]);
      expect(d.send('apaga o lançamento de 80 de ontem')!.text, contains('Pizza'));
    });
  });

  group('chips presos ao card (ChatDraftTracker)', () {
    test('chip do rascunho pendente responde a ele', () {
      final t = ChatDraftTracker();
      final k = t.startDraft();
      expect(t.targetFor(k), isA<ChipOnActiveDraft>());
      expect(t.continueDraft(), k, reason: 'a resposta mantém a identidade do card');
    });

    test('chip de um card já gravado edita o que ele virou', () {
      final t = ChatDraftTracker();
      final k = t.startDraft();
      t.saved(['1700000004821']);
      t.startDraft(); // outro assunto agora
      final target = t.targetFor(k);
      expect(target, isA<ChipOnSavedRecords>());
      expect((target as ChipOnSavedRecords).transactionIds, ['1700000004821']);
    });

    test('chip de um card deixado de lado traz o rascunho de volta', () {
      final t = ChatDraftTracker();
      final old = t.startDraft();
      final now2 = t.startDraft(); // frase nova substituiu o rascunho antigo
      expect(t.targetFor(old), isA<ChipOnStaleDraft>());
      expect(t.targetFor(now2), isA<ChipOnActiveDraft>());
      t.reactivate(old);
      expect(t.targetFor(old), isA<ChipOnActiveDraft>());
    });

    test('a edição gerada pelo chip ("muda o #código pra pix") funciona', () {
      final c = fresh([tx('1700000004821', 'Farmácia', 30, today, pay: 'debit_card', cat: 'health')]);
      expect(c.send('muda o #4821 pra pix')!.route, 'edited');
      expect(c.repo.transactions.single.paymentMethod, 'pix');
      expect(c.send('muda o #4821 pra em 3x')!.route, 'edited');
      expect(c.repo.transactions.single.installments, 3);
    });
  });
}
