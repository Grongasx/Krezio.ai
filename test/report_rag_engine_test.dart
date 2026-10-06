import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/financial_report_rag_engine.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/ai/temporal_date_parser.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

void main() {
  late LocalFinancialNlpEngine nlp;

  setUpAll(() async {
    final modelFile = File('models/on_device/krezio_nlp_model.json');
    final jsonStr = await modelFile.readAsString();
    nlp = LocalFinancialNlpEngine.fromJsonString(jsonStr);
  });
  group('TemporalDateParser Tests', () {
    final fixedDate = DateTime(2026, 9, 15, 14, 0); // Tuesday, Sep 15, 2026

    test('parses "essa semana" correctly', () {
      final range = TemporalDateParser.parse('quem está me devendo essa semana', referenceDate: fixedDate);
      expect(range, isNotNull);
      expect(range!.label, 'esta semana');
      // Monday Sep 14 to Sunday Sep 20
      expect(range.start.day, 14);
      expect(range.end.day, 20);
    });

    test('parses "começo do mês que vem" correctly', () {
      final range = TemporalDateParser.parse('quem tá me devendo pra me pagar no começo do mês que vem', referenceDate: fixedDate);
      expect(range, isNotNull);
      expect(range!.start.month, 10);
      expect(range.start.day, 1);
      expect(range.end.day, 10);
    });

    test('parses "esse mês" correctly', () {
      final range = TemporalDateParser.parse('quanto eu gastei com ifood esse mês', referenceDate: fixedDate);
      expect(range, isNotNull);
      expect(range!.start.month, 9);
      expect(range.start.day, 1);
      expect(range.end.day, 30);
    });

    test('parses "semana que vem" correctly', () {
      final range = TemporalDateParser.parse('quais boletos vencem semana que vem', referenceDate: fixedDate);
      expect(range, isNotNull);
      // Next Monday Sep 21 to Sunday Sep 27
      expect(range!.start.day, 21);
      expect(range.end.day, 27);
    });

    test('parses "fim do mês" correctly', () {
      final range = TemporalDateParser.parse('gastos até o fim do mês', referenceDate: fixedDate);
      expect(range, isNotNull);
      expect(range!.start.day, 20);
      expect(range.end.day, 30);
    });
  });

  group('FinancialRepository Analytical Queries', () {
    late FinancialRepository repo;

    setUp(() {
      repo = FinancialRepository();
    });

    test('getSpendingByCategoryOrTerm finds seeded supermarket transaction', () {
      final matches = repo.getSpendingByCategoryOrTerm('mercado');
      expect(matches.isNotEmpty, isTrue);
      expect(matches.first.category, 'supermarket');
      expect(matches.first.amount, 380.50);
    });

    test('getSpendingByCategoryOrTerm with empty term matches all expenses (generic query)', () {
      final matches = repo.getSpendingByCategoryOrTerm('');
      // 4 seeded expenses: Carrefour, Aluguel, Academia, Uber (the seeded salary is income, not expense)
      expect(matches.length, 4);
      final total = matches.fold(0.0, (acc, tx) => acc + tx.amount);
      expect(total, closeTo(1948.40, 0.001));
    });

    test('getActiveDebtors retrieves seeded João reminder', () {
      final debtors = repo.getActiveDebtors();
      expect(debtors.isNotEmpty, isTrue);
      final joao = debtors.firstWhere((d) => d.personName == 'João');
      expect(joao.amount, 150.00);
      expect(joao.type, ReminderType.loanReceivable);
    });

    test('addBillWithMargin creates recurrent transaction with margin', () {
      repo.addBillWithMargin(
        title: 'Boleto de Energia Elétrica',
        billingDay: 1,
        dueDay: 5,
        amount: 220.00,
      );

      final bills = repo.transactions.where((t) => t.title == 'Boleto de Energia Elétrica').toList();
      expect(bills.isNotEmpty, isTrue);
      expect(bills.first.billingDay, 1);
      expect(bills.first.dueDay, 5);
      expect(bills.first.paymentMarginDays, 4);
    });
  });

  group('FinancialReportRagEngine RAG Tests', () {
    late FinancialRepository repo;
    late FinancialReportRagEngine rag;

    setUp(() {
      repo = FinancialRepository();
      rag = FinancialReportRagEngine(repository: repo);
    });

    test('identifies and answers "quem está me devendo"', () {
      expect(FinancialReportRagEngine.isReportQuery('quem está me devendo'), isTrue);

      final result = rag.generateReport('quem está me devendo');
      expect(result.intent, ReportIntent.debtors);
      expect(result.spokenText, contains('João'));
      expect(result.spokenText, contains('150,00'));
      expect(result.formattedText, contains('Cobranças'));
    });

    test('answers "quanto eu gastei com supermercado este mês"', () {
      expect(FinancialReportRagEngine.isReportQuery('quanto eu gastei com supermercado este mês'), isTrue);

      final result = rag.generateReport('quanto eu gastei com supermercado este mês');
      expect(result.intent, ReportIntent.spending);
      expect(result.spokenText, contains('380,50'));
      expect(result.formattedText, contains('Supermercado Carrefour'));
    });

    test('answers "quais boletos tenho que pagar"', () {
      expect(FinancialReportRagEngine.isReportQuery('quais boletos tenho que pagar essa semana'), isTrue);

      final result = rag.generateReport('quais boletos tenho que pagar essa semana');
      expect(result.intent, ReportIntent.bills);
      expect(result.formattedText, contains('Boletos'));
    });

    test('answers generic "quanto eu gastei esse mês" without naming a category', () {
      expect(FinancialReportRagEngine.isReportQuery('quanto eu gastei esse mês'), isTrue);

      final result = rag.generateReport('quanto eu gastei esse mês');
      expect(result.intent, ReportIntent.spending);
      // Regression: used to always report R$ 0,00 because the fallback term
      // 'despesas gerais' was used as a literal filter that never matched real data.
      expect(result.spokenText, isNot(contains('R\$ 0,00')));
      expect(result.formattedText, isNot(contains('Nenhuma despesa correspondente')));
      expect(result.formattedText, contains('1.948,40'));
    });

    test('general overview answers correctly', () {
      final result = rag.generateReport('como estão minhas finanças');
      expect(result.intent, ReportIntent.overview);
      expect(result.spokenText, contains('saldo geral'));
      expect(result.formattedText, contains('Resumo Financeiro Geral'));
    });
  });

  group('Chart Requests in Reports', () {
    late FinancialRepository repo;
    late FinancialReportRagEngine rag;

    setUp(() {
      repo = FinancialRepository();
      rag = FinancialReportRagEngine(repository: repo);
    });

    test('a report query without "gráfico" never attaches a chart', () {
      final result = rag.generateReport('quem está me devendo');
      expect(result.chart, isNull);
    });

    test('wantsChart recognizes graph-flavored phrasing', () {
      expect(FinancialReportRagEngine.wantsChart('me mostra um gráfico dos meus gastos'), isTrue);
      expect(FinancialReportRagEngine.wantsChart('quero visualizar em gráfico quem me deve'), isTrue);
      expect(FinancialReportRagEngine.wantsChart('gastei 50 no mercado'), isFalse);
    });

    test('"me mostra um gráfico dos meus gastos esse mês" is recognized and attaches a category chart', () {
      final query = 'me mostra um gráfico dos meus gastos esse mês';
      expect(FinancialReportRagEngine.isReportQuery(query), isTrue);

      final result = rag.generateReport(query);
      expect(result.intent, ReportIntent.spending);
      expect(result.chart, isNotNull);
      expect(result.chart!.categoryValues, isNotNull);
      expect(result.chart!.barValues, isNull);
      // Seeded expenses: Carrefour (supermarket), Aluguel (housing), Academia (health), Uber (transport)
      final byCategory = result.chart!.categoryValues!;
      expect(byCategory['supermarket'], closeTo(380.50, 0.001));
      expect(byCategory['housing'], closeTo(1400.00, 0.001));
    });

    test('"gráfico de quem está me devendo" attaches a bar chart with debtor totals', () {
      final query = 'gráfico de quem está me devendo';
      expect(FinancialReportRagEngine.isReportQuery(query), isTrue);

      final result = rag.generateReport(query);
      expect(result.intent, ReportIntent.debtors);
      expect(result.chart, isNotNull);
      expect(result.chart!.barValues, isNotNull);
      expect(result.chart!.categoryValues, isNull);
      final bar = result.chart!.barValues!.firstWhere((e) => e.key == 'João');
      expect(bar.value, closeTo(150.00, 0.001));
    });

    test('"gráfico das minhas finanças" attaches a bar chart with income/expense/receivable/balance', () {
      final query = 'gráfico das minhas finanças';
      expect(FinancialReportRagEngine.isReportQuery(query), isTrue);

      final result = rag.generateReport(query);
      expect(result.intent, ReportIntent.overview);
      expect(result.chart, isNotNull);
      final labels = result.chart!.barValues!.map((e) => e.key).toSet();
      expect(labels, containsAll(['Receitas', 'Despesas', 'A Receber', 'Saldo']));
    });
  });

  group('Margin Bill Natural Language Extraction', () {
    test('extracts "o boleto de luz cai todo dia 1, porém vence no dia 5"', () {
      final draft = nlp.parse('o boleto de luz cai todo dia 1, porém vence no dia 5');
      expect(draft.isRecurrent, isTrue);
      expect(draft.billingDay, 1);
      expect(draft.dueDay, 5);
      expect(draft.paymentMarginDays, 4);
    });

    test('extracts "boleto de internet cai dia 10 mas vence no dia 20"', () {
      final draft = nlp.parse('boleto de internet cai dia 10 mas vence no dia 20');
      expect(draft.isRecurrent, isTrue);
      expect(draft.billingDay, 10);
      expect(draft.dueDay, 20);
      expect(draft.paymentMarginDays, 10);
    });

    test('recognizes report query and tags isReportQuery', () {
      final draft = nlp.parse('quem está me devendo');
      expect(draft.isReportQuery, isTrue);
      expect(draft.intent, 'query');
      expect(draft.reportType, 'debtors');
    });
  });

  group('Teste do Macaco: Robustez, Caos, Gírias e Edge Cases', () {
    final fixedDate = DateTime(2026, 9, 15, 14, 0); // Terça-feira, 15 de Setembro de 2026
    late FinancialRepository repo;
    late FinancialReportRagEngine rag;

    setUp(() {
      repo = FinancialRepository();
      rag = FinancialReportRagEngine(repository: repo);
    });

    test('Macaco em TemporalDateParser: Caixa alta, pontuação caótica, abreviações e erros', () {
      // Caixa mista e pontuação extrema
      final t1 = TemporalDateParser.parse('  qUeM Ta ME DeVeNdo nEsSa sMana??? !!', referenceDate: fixedDate);
      expect(t1, isNotNull);
      expect(t1!.label, 'esta semana');

      // "q vem" em vez de "que vem" e sem acento
      final t2 = TemporalDateParser.parse('quem me deve pro comeco do mes q vem?', referenceDate: fixedDate);
      expect(t2, isNotNull);
      expect(t2!.start.month, 10);
      expect(t2.start.day, 1);
      expect(t2.end.day, 10);

      // "comecinho do proximo mes"
      final t3 = TemporalDateParser.parse('cobrar no comecinho do proximo mes', referenceDate: fixedDate);
      expect(t3, isNotNull);
      expect(t3!.start.month, 10);
      expect(t3.start.day, 1);

      // "final do mes q vem"
      final t4 = TemporalDateParser.parse('boletos pro final do mes q vem', referenceDate: fixedDate);
      expect(t4, isNotNull);
      expect(t4!.start.month, 10);
      expect(t4.start.day, 20);

      // "proximos 07 dias" com zero à esquerda
      final t5 = TemporalDateParser.parse('gastos nos proximos 07 dias', referenceDate: fixedDate);
      expect(t5, isNotNull);
      expect(t5!.label, contains('próximos 7 dias'));

      // Texto sem referência temporal não quebra nem explode
      final t6 = TemporalDateParser.parse('coxinha de frango com catupiry 15 reais', referenceDate: fixedDate);
      expect(t6, isNull);

      // String vazia e somente espaços/símbolos
      expect(TemporalDateParser.parse('', referenceDate: fixedDate), isNull);
      expect(TemporalDateParser.parse('   !!! ??? ... ### ', referenceDate: fixedDate), isNull);
    });

    test('Macaco em FinancialRepository: Termos vazios, filtros invertidos e valores limites', () {
      // Busca termo com espaços extras e case-insensitive
      final s1 = repo.getSpendingByCategoryOrTerm('  MERCADO  ');
      expect(s1.isNotEmpty, isTrue);

      // Termo inexistente retorna lista vazia de forma segura
      final s2 = repo.getSpendingByCategoryOrTerm('astronauta_intergalactico_xyz_999');
      expect(s2, isEmpty);

      // Inversão caótica de datas (start posterior ao end) não gera exception
      final start = DateTime(2026, 9, 20);
      final end = DateTime(2026, 9, 10);
      final s3 = repo.getTransactionsBetween(start, end);
      expect(s3, isEmpty);

      final s4 = repo.getSpendingByCategoryOrTerm('mercado', start: start, end: end);
      expect(s4, isEmpty);

      // Devedores em período sem registros retorna lista vazia segura
      final dPast = repo.getActiveDebtors(
        start: DateTime(2020, 1, 1),
        end: DateTime(2020, 1, 31),
      );
      expect(dPast, isEmpty);

      // Inserção de boleto com margem com dia limite (> 28) é ajustado com clamp
      repo.addBillWithMargin(
        title: 'Boleto Fim de Mês',
        billingDay: 25,
        dueDay: 30,
        amount: 500.0,
      );
      final added = repo.transactions.firstWhere((t) => t.title == 'Boleto Fim de Mês');
      expect(added.paymentMarginDays, 5);
      expect(added.date.day, lessThanOrEqualTo(28));
    });

    test('Macaco em FinancialReportRagEngine: Gírias, vocativos e linguagem coloquial', () {
      // Vocativo do César + gíria "ta me devendo" + pontuação caótica
      final q1 = 'CESAR!! quem ta me devendo essa semana??? ... ';
      expect(FinancialReportRagEngine.isReportQuery(q1), isTrue);
      final r1 = rag.generateReport(q1);
      expect(r1.intent, ReportIntent.debtors);
      expect(r1.spokenText, isNotEmpty);
      expect(r1.formattedText, contains('Cobranças'));

      // "qto gastei com ifood nesse mes mano"
      final q2 = 'qto gastei com ifood nesse mes mano';
      expect(FinancialReportRagEngine.isReportQuery(q2), isTrue);
      final r2 = rag.generateReport(q2);
      expect(r2.intent, ReportIntent.spending);
      expect(r2.spokenText, contains('ifood'));

      // "quais boletos ou contas vence essa semana??"
      final q3 = 'quais boletos ou contas vence essa semana??';
      expect(FinancialReportRagEngine.isReportQuery(q3), isTrue);
      final r3 = rag.generateReport(q3);
      expect(r3.intent, ReportIntent.bills);

      // "como ta minhas financas no geral cesar"
      final q4 = 'como ta minhas financas no geral cesar';
      expect(FinancialReportRagEngine.isReportQuery(q4), isTrue);
      final r4 = rag.generateReport(q4);
      expect(r4.intent, ReportIntent.overview);

      // Pergunta arbitrária que não tem relação com finanças não ativa relatório
      final qRandom = 'qual a cor do cavalo branco de napoleao?';
      expect(FinancialReportRagEngine.isReportQuery(qRandom), isFalse);
    });

    test('Macaco em Margem de Boletos: Abreviaturas ("td dia"), zeros à esquerda e pontuação', () {
      // "td dia 01" e "vence no dia 05"
      final d1 = nlp.parse('o boleto da internet cai td dia 01, mas vence no dia 05');
      expect(d1.isRecurrent, isTrue);
      expect(d1.billingDay, 1);
      expect(d1.dueDay, 5);
      expect(d1.paymentMarginDays, 4);

      // César vocativo + "cai dia 2 e vence dia 12"
      final d2 = nlp.parse('CESAR! boleto de luz cai dia 2 e vence dia 12');
      expect(d2.isRecurrent, isTrue);
      expect(d2.billingDay, 2);
      expect(d2.dueDay, 12);
      expect(d2.paymentMarginDays, 10);

      // "cai todo dia 10 porem vence dia 15"
      final d3 = nlp.parse('boleto do condominio cai todo dia 10 porem vence dia 15');
      expect(d3.isRecurrent, isTrue);
      expect(d3.billingDay, 10);
      expect(d3.dueDay, 15);
      expect(d3.paymentMarginDays, 5);
    });
  });

  group('QA CONV-016: "alguém tá me devendo?" é relatório de devedores', () {
    test('é pergunta de relatório, não empréstimo novo', () {
      for (final q in ['alguém tá me devendo?', 'alguem esta me devendo?', 'tem alguém me devendo?', 'alguém me deve?']) {
        expect(FinancialReportRagEngine.isReportQuery(q), isTrue, reason: q);
        final draft = nlp.parse(q);
        expect(draft.isReminder, isFalse, reason: q);
        expect(draft.intent, 'query', reason: q);
      }
      final repo = FinancialRepository();
      final report = FinancialReportRagEngine(repository: repo).generateReport('alguém tá me devendo?');
      expect(report.intent, ReportIntent.debtors);
      expect(report.spokenText, contains('João'));
    });
  });

  group('QA CONV-017: gasto por categoria em português e por forma de pagamento', () {
    test('nome da categoria em português encontra os lançamentos', () {
      final repo = FinancialRepository();
      double total(String term) => repo.getTotalSpendingByCategoryOrTerm(term);
      expect(total('transporte'), 48.0);
      expect(total('saúde'), closeTo(119.90, 0.001));
      expect(total('alimentação'), total('lazer'));
      expect(total('mercado'), greaterThanOrEqualTo(380.50));
    });

    test('forma de pagamento filtra por pagamento, não por texto', () {
      final repo = FinancialRepository();
      final pix = repo.getSpendingByCategoryOrTerm('pix');
      expect(pix, isNotEmpty);
      expect(pix.every((t) => t.paymentMethod == 'pix'), isTrue);
      expect(repo.getTotalSpendingByCategoryOrTerm('pix'), 48.0);
      expect(repo.getSpendingByCategoryOrTerm('débito').every((t) => t.paymentMethod == 'debit_card'), isTrue);
    });

    test('termo no fim da pergunta (com "?") não vira "despesas gerais"', () {
      final repo = FinancialRepository();
      final rag = FinancialReportRagEngine(repository: repo);
      final saude = rag.generateReport('quanto gastei em saúde?');
      expect(saude.spokenText, isNot(contains('nenhum gasto')));
      expect(saude.formattedText, contains('119,90'));
      final alimentacao = rag.generateReport('quanto gastei com alimentação?');
      expect(alimentacao.formattedText, isNot(contains('despesas gerais')));
    });
  });
}
