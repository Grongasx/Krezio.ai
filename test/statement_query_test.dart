import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/services/statement_query.dart';

FinancialTransaction tx(String id, String title, double amount, DateTime date,
        {TransactionType type = TransactionType.expense, String cat = 'supermarket', String pay = 'pix', int? inst}) =>
    FinancialTransaction(
        id: id, title: title, amount: amount, type: type, category: cat, paymentMethod: pay, date: date, installments: inst);

void main() {
  final now = DateTime(2026, 10, 16, 15);
  final all = [
    tx('1', 'Açougue', 80, DateTime(2026, 10, 16, 9), cat: 'supermarket'),
    tx('2', 'Salário', 5000, DateTime(2026, 10, 5), type: TransactionType.income, cat: 'salary'),
    tx('3', 'Uber', 30, DateTime(2026, 10, 15, 20), cat: 'transport', pay: 'debit_card'),
    tx('4', 'Mercado', 120, DateTime(2026, 10, 15, 10)),
    tx('5', 'TV', 2000, DateTime(2026, 9, 20), cat: 'housing', pay: 'credit_card', inst: 10),
    tx('6', 'Poupança', 500, DateTime(2026, 10, 16, 8), type: TransactionType.transfer, cat: 'investment'),
  ];

  test('busca ignora acento e maiúscula', () {
    final r = StatementQuery.apply(all, const StatementFilter(text: 'acougue'), now: now);
    expect(r.map((t) => t.id), ['1']);
    expect(StatementQuery.apply(all, const StatementFilter(text: 'SALARIO'), now: now).single.id, '2');
  });

  test('busca também pelo nome da categoria', () {
    final r = StatementQuery.apply(all, const StatementFilter(text: 'transporte'), now: now,
        categoryName: (c) => c == 'transport' ? 'Transporte' : c);
    expect(r.single.id, '3');
  });

  test('filtros se combinam', () {
    final f = const StatementFilter(period: StatementPeriod.thisMonth, type: TransactionType.expense, paymentMethod: 'pix');
    expect(StatementQuery.apply(all, f, now: now).map((t) => t.id), ['1', '4']);
    expect(StatementQuery.apply(all, const StatementFilter(period: StatementPeriod.lastMonth), now: now).single.id, '5');
    expect(StatementQuery.apply(all, const StatementFilter(onlyInstallments: true), now: now).single.id, '5');
    final custom = StatementFilter(period: StatementPeriod.custom, from: DateTime(2026, 10, 15), to: DateTime(2026, 10, 15));
    expect(StatementQuery.apply(all, custom, now: now).map((t) => t.id), ['3', '4']);
  });

  test('agrupa por dia, mais novo primeiro, com o total do dia', () {
    final days = StatementQuery.groupByDay(StatementQuery.apply(all, const StatementFilter(), now: now));
    expect(days.map((d) => d.day.day), [16, 15, 5, 20]);
    expect(days[0].total, -80, reason: 'transferência não altera o total');
    expect(days[1].total, -150);
    expect(days[2].total, 5000);
  });

  test('cabeçalhos: Hoje, Ontem, dia da semana', () {
    expect(StatementQuery.dayHeader(DateTime(2026, 10, 16), now), 'Hoje');
    expect(StatementQuery.dayHeader(DateTime(2026, 10, 15), now), 'Ontem');
    expect(StatementQuery.dayHeader(DateTime(2026, 9, 28), now), 'Seg, 28/09');
    expect(StatementQuery.dayHeader(DateTime(2025, 12, 25), now), 'Qui, 25/12/2025');
  });

  test('mil lançamentos filtram e agrupam rápido', () {
    final many = [
      for (var i = 0; i < 1000; i++) tx('$i', 'Item $i', 10, now.subtract(Duration(hours: i * 7))),
    ];
    final sw = Stopwatch()..start();
    final days = StatementQuery.groupByDay(StatementQuery.apply(many, const StatementFilter(text: 'item'), now: now));
    expect(days.expand((d) => d.transactions).length, 1000);
    expect(sw.elapsedMilliseconds, lessThan(200));
  });
}
