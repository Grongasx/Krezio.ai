import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/financial_qa_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A repository holding exactly [txs] (no demo seed), so answers are exact.
Future<FinancialRepository> repoWith(List<FinancialTransaction> txs) async {
  SharedPreferences.setMockInitialValues({});
  final repo = FinancialRepository();
  await repo.clearAllData();
  for (final t in txs.reversed) {
    repo.addTransaction(t);
  }
  return repo;
}

FinancialTransaction tx(String id, String title, double amount, DateTime date,
        {TransactionType type = TransactionType.expense, String category = 'expense_other', String pay = 'pix'}) =>
    FinancialTransaction(id: id, title: title, amount: amount, type: type, category: category, paymentMethod: pay, date: date);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 12);
  final lastMonth = DateTime(now.year, now.month - 1, 15, 12);

  late FinancialRepository repo;
  late FinancialQaEngine qa;

  setUp(() async {
    repo = await repoWith([
      tx('1', 'Salário', 5000, today, type: TransactionType.income, category: 'salary'),
      tx('2', 'Aluguel do Apartamento', 1400, today, category: 'housing', pay: 'bank_slip'),
      tx('3', 'Mercado Extra', 300, today, category: 'supermarket', pay: 'debit_card'),
      tx('4', 'Farmácia', 80, today, category: 'health', pay: 'pix'),
      tx('5', 'Uber', 20, today, category: 'transport', pay: 'pix'),
      tx('6', 'Mercado antigo', 999, lastMonth, category: 'supermarket', pay: 'pix'),
    ]);
    qa = FinancialQaEngine(repository: repo, now: () => today);
  });

  String ask(String q) {
    final a = qa.answer(q);
    expect(a, isNotNull, reason: 'sem resposta para "$q"');
    return a!.text;
  }

  group('FEAT-009 / CONV-014/015 — perguntas sobre os dados', () {
    test('maior gasto do mês', () {
      final t = ask('qual meu maior gasto?');
      expect(t, contains('Aluguel do Apartamento'));
      expect(t, contains('R\$ 1.400,00'));
      expect(t, isNot(contains('999')), reason: 'mês passado fica fora');
    });

    test('maiores gastos (lista) e menor gasto', () {
      expect(ask('quais foram meus maiores gastos esse mês?'), allOf(contains('Aluguel'), contains('Mercado Extra'), contains('Farmácia')));
      expect(ask('qual foi o meu menor gasto?'), contains('Uber'));
    });

    test('categoria em que mais gasto', () {
      final t = ask('qual categoria eu mais gasto?');
      expect(t, contains('Moradia'));
      expect(t, contains('R\$ 1.400,00'));
      expect(ask('onde eu mais gastei esse mês?'), contains('Moradia'));
    });

    test('saldo, "quanto tenho na conta" e "quanto sobrou"', () {
      // 5000 − 1400 − 300 − 80 − 20 − 999 = 2201
      for (final q in ['qual meu saldo?', 'quanto eu tenho na conta?', 'quanto sobrou?', 'meu saldo']) {
        expect(ask(q), contains('R\$ 2.201,00'), reason: q);
      }
    });

    test('tô no vermelho? — positivo e negativo', () {
      expect(ask('tô no vermelho?'), startsWith('Não'));
      repo.addTransaction(tx('7', 'Carro', 9000, today));
      expect(ask('to no vermelho'), startsWith('Sim'));
      expect(ask('estou negativado?'), contains('negativo'));
    });

    test('receitas do mês', () {
      final t = ask('quanto recebi esse mês?');
      expect(t, contains('R\$ 5.000,00'));
      expect(t, contains('Salário'));
      expect(ask('quanto ganhei de salário?'), contains('R\$ 5.000,00'));
    });

    test('últimos lançamentos, com N', () {
      final t = ask('quais foram meus últimos lançamentos?');
      expect(t, contains('Uber'));
      expect(t, contains('Salário'));
      expect(t, isNot(contains('Mercado antigo')), reason: 'mostra só 5');
      expect(ask('me mostra os últimos 2 lançamentos').split('\n- ').length - 1, 2);
    });

    test('filtro por descrição: "quanto paguei de aluguel?"', () {
      expect(ask('quanto paguei de aluguel?'), contains('R\$ 1.400,00'));
      expect(ask('quanto foi o aluguel?'), contains('R\$ 1.400,00'));
    });

    test('filtro por forma de pagamento: pix, débito, crédito', () {
      final pix = ask('quanto gastei no pix esse mês?');
      expect(pix, contains('R\$ 100,00')); // farmácia 80 + uber 20
      expect(pix, contains('no Pix'));
      expect(ask('quanto gastei no débito?'), contains('R\$ 300,00'));
      expect(ask('quanto gastei no crédito?'), contains('não teve gastos'));
    });

    test('filtro por nome de categoria em português', () {
      expect(ask('quanto gastei em saúde?'), allOf(contains('R\$ 80,00'), contains('saúde')));
      expect(ask('quanto gastei com transporte esse mês?'), contains('R\$ 20,00'));
      expect(ask('quanto gastei com mercado no mês passado?'), contains('R\$ 999,00'));
    });

    test('orçamento diário até o fim do mês mostra a conta', () {
      final t = ask('quanto posso gastar por dia até o fim do mês?');
      final lastDay = DateTime(today.year, today.month + 1, 0).day;
      final daysLeft = lastDay - today.day + 1;
      // Este mês: 5000 − 1800 = 3200 livres (sem contas recorrentes).
      // Formato BRL com separador de milhar: no fim do mês (poucos dias) passa de R$ 1.000.
      final perDay = (3200 / daysLeft)
          .toStringAsFixed(2)
          .replaceAll('.', ',')
          .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+,)'), (m) => '${m[1]}.');
      expect(t, contains(perDay));
      expect(t, contains('$daysLeft dia'));
    });

    test('comparação com o mês passado', () {
      final t = ask('estou gastando mais que no mês passado?');
      expect(t, contains('R\$ 1.800,00'));
      expect(t, contains('R\$ 999,00'));
      expect(t, contains('a mais'));
    });

    test('quanto ainda posso gastar com uma categoria (orçamento)', () {
      final t = ask('quanto ainda posso gastar com saúde?');
      expect(t, contains('Saúde & Farmácia'));
      expect(t, contains('R\$ 220,00')); // limite 300 − 80
    });

    test('metas: sem metas, uma meta, meta por nome', () {
      expect(ask('quanto falta pra minha meta?'), contains('ainda não tem metas'));
      repo.addGoal(FinancialGoal(id: 'g1', title: 'Viagem', targetAmount: 5000, savedAmount: 1000));
      final t = ask('quanto falta pra minha meta?');
      expect(t, contains('Viagem'));
      expect(t, contains('R\$ 4.000,00'));
      expect(ask('como está minha meta da viagem?'), contains('20%'));
    });

    test('quantas vezes e última vez', () {
      expect(ask('quantas vezes eu fui no uber esse mês?'), contains('1 lançamento'));
      expect(ask('quando foi a última vez que paguei o aluguel?'), contains('Aluguel do Apartamento'));
    });

    test('contas vencendo e quem me deve continuam respondidas', () {
      expect(qa.answer('tenho conta vencendo?')!.route, 'report:bills');
      expect(qa.answer('quem me deve?')!.route, 'report:debtors');
    });
  });

  group('não dispara em lançamentos normais', () {
    for (final p in [
      'gastei 50 no mercado',
      'apaguei a luz e gastei 50',
      'o mercado de ontem estava cheio, gastei 80',
      'fiquei no vermelho depois de gastar 500 no mercado',
      'paguei o saldo do cartão, 500 no pix',
      'recebi 300 do joão',
      'posso comprar um celular de 2000?',
    ]) {
      test(p, () => expect(FinancialQaEngine.parse(p), isNull));
    }
  });
}
