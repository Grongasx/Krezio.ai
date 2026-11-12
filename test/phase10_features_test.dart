import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/bill_split_parser.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/config/app_environment.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:krezio_ai/backend/services/currency_service.dart';
import 'package:krezio_ai/backend/services/money.dart';
import 'package:krezio_ai/backend/services/notification_service.dart';
import 'package:krezio_ai/backend/services/statement_import.dart';
import 'package:krezio_ai/backend/services/statement_query.dart';
import 'package:krezio_ai/backend/services/tax_report.dart';
import 'package:krezio_ai/frontend/features/home_widget/home_widget_sync.dart';
import 'package:krezio_ai/frontend/navigation/krezio_routes.dart';
import 'package:krezio_ai/frontend/theme/krezio_theme.dart';

FinancialRepository emptyRepo() {
  final r = FinancialRepository();
  r.replaceAllFromCloud(transactions: [], reminders: [], budgets: r.budgets.toList(), goals: [], categoryOverrides: {});
  return r;
}

const ofx = '''OFXHEADER:100
<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261003120000[-3:BRT]<TRNAMT>-45.90<FITID>A1<MEMO>PAG*IFOOD
</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261005<TRNAMT>5000.00<FITID>A2<NAME>SALARIO EMPRESA X</NAME>
</STMTTRN>
</BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>''';

void main() {
  group('10.1 importar extrato', () {
    test('OFX: valores, datas, sinais e títulos legíveis', () {
      final e = StatementImport.parseOfx(ofx);
      expect(e.length, 2);
      expect(e[0].amount, -45.90);
      expect(e[0].date, DateTime(2026, 10, 3));
      expect(e[0].description, 'Pag Ifood');
      expect(e[1].amount, 5000);
      expect(e[1].bankId, 'A2');
    });

    test('CSV com cabeçalho em qualquer ordem, ; ou , e valores brasileiros', () {
      const csv = '﻿Descrição;Data;Valor\n"Mercado; Centro";16/10/2026;-1.234,56\nPix recebido;15/10/2026;200,00\n';
      final e = StatementImport.parseCsv(csv);
      expect(e.map((x) => x.amount), [-1234.56, 200]);
      expect(e.first.description, 'Mercado; Centro');
      final nubank = StatementImport.parseCsv('date,title,amount\n2026-10-10,Uber,23.5\n', expensesPositive: true);
      expect(nubank.single.amount, -23.5);
    });

    test('importar o mesmo arquivo duas vezes não duplica nada', () {
      final repo = emptyRepo();
      var seq = 0;
      List<FinancialTransaction> run() {
        final entries = StatementImport.markDuplicates(StatementImport.parseOfx(ofx), repo.transactions);
        final txs = StatementImport.toTransactions(entries, accountId: 'main', newId: () => 'imp-${seq++}');
        txs.forEach(repo.addTransaction);
        return txs;
      }

      expect(run().length, 2);
      expect(run(), isEmpty);
      expect(repo.transactions.length, 2);
      expect(repo.transactions.firstWhere((t) => t.amount == 5000).type, TransactionType.income);
    });

    test('linha repetida dentro do próprio arquivo conta uma vez', () {
      const csv = 'data;descricao;valor\n16/10/2026;Padaria;-10,00\n16/10/2026;Padaria;-10,00\n';
      final marked = StatementImport.markDuplicates(StatementImport.parseCsv(csv), const []);
      expect(marked.where((e) => !e.isDuplicate).length, 1);
    });
  });

  group('10.2 dividir conta', () {
    test('"o jantar deu 240, dividi com mais 3"', () {
      final s = BillSplitParser.parse('o jantar deu 240, dividi com mais 3')!;
      expect([s.total, s.people, s.myShare, s.toReceive], [240, 4, 60, 180]);
      expect(s.description, 'Jantar');
      final named = BillSplitParser.parse('a pizza foi 90 e rachei com o joão e a ana')!;
      expect(named.others, ['João', 'Ana']);
      expect(named.myShare, 30);
    });

    test('parcelado e plano não são divisão', () {
      expect(BillSplitParser.parse('dividi a tv em 3x no cartão de 1500'), isNull);
      expect(BillSplitParser.parse('vou dividir o jantar de 200 com mais 1'), isNull);
      expect(BillSplitParser.parse('gastei 50 no mercado'), isNull);
    });

    test('pelo César: gasto meu + a receber, e um "desfaz" tira tudo', () async {
      final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
      final repo = emptyRepo();
      final a = CesarAssistant(repository: repo, engine: engine);
      a.beginTurn();
      final r = a.handleCommand('o jantar deu 240, dividi com mais 3')!;
      expect(r.route, 'split');
      expect(repo.transactions.single.amount, 60);
      final debt = repo.reminders.single;
      expect([debt.amount, debt.type], [180, ReminderType.loanReceivable]);
      a.beginTurn();
      expect(a.handleCommand('desfaz')!.route, 'undo');
      expect(repo.transactions, isEmpty);
      expect(repo.reminders, isEmpty);
    });

    test('"fui em um jantar, o total deu 320, dividimos em 3" e variações reais', () {
      final s1 = BillSplitParser.parse('fui em um jantar, o total deu 320, dividimos em 3')!;
      expect(s1.description, 'Jantar');
      expect(s1.total, 320.0);
      expect(s1.people, 3);
      expect(s1.myShare, 106.67);
      expect(s1.toReceive, 213.33);
      expect(s1.onlyMyShare, isFalse);

      final s2 = BillSplitParser.parse('rachei uma pizza de 120 com mais 2')!;
      expect(s2.description, 'Pizza');
      expect([s2.total, s2.people, s2.myShare], [120.0, 3, 40.0]);

      final s3 = BillSplitParser.parse('rachei um uber de 45 com o lucas')!;
      expect(s3.description, 'Uber');
      expect(s3.others, ['Lucas']);
      expect([s3.total, s3.people, s3.myShare], [45.0, 2, 22.5]);

      final s4 = BillSplitParser.parse('a conta do bar deu R\$ 1.200,00, dividimos entre 4 amigos')!;
      expect(s4.description, 'Bar');
      expect([s4.total, s4.people, s4.myShare], [1200.0, 4, 300.0]);

      final s5 = BillSplitParser.parse('dividi 180 com 2 amigos')!;
      expect([s5.total, s5.people, s5.myShare], [180.0, 3, 60.0]);

      final s6 = BillSplitParser.parse('dividimos em 3, o total deu 300')!;
      expect([s6.total, s6.people, s6.myShare], [300.0, 3, 100.0]);

      final sExact = BillSplitParser.parse('o jantar deu 320, rachei com o joão e a ana')!;
      expect(sExact.myShare + sExact.shareForOther(0) + sExact.shareForOther(1), closeTo(320.0, 0.001));

      expect(BillSplitParser.parse('jantar deu -320, dividimos em 3'), isNull);
      expect(BillSplitParser.parse('jantar deu 99999999, dividimos em 3'), isNull);
    });

    test('"cada um pagou sua parte" grava só a minha despesa sem cobrança, e baixa sem nome funciona', () async {
      final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());

      final repoOnlyMine = emptyRepo();
      final a1 = CesarAssistant(repository: repoOnlyMine, engine: engine);
      a1.beginTurn();
      final r1 = a1.handleCommand('fui em um jantar, o total deu 320, dividimos em 3 e cada um pagou sua parte')!;
      expect(r1.route, 'split');
      expect(repoOnlyMine.transactions.single.title, 'Jantar');
      expect(repoOnlyMine.transactions.single.amount, 106.67);
      expect(repoOnlyMine.reminders, isEmpty);

      final repoGroup = emptyRepo();
      final a2 = CesarAssistant(repository: repoGroup, engine: engine);
      a2.beginTurn();
      final r2 = a2.handleCommand('fui em um jantar, o total deu 320, dividimos em 3')!;
      expect(r2.route, 'split');
      expect(r2.text, contains('Jantar'));
      expect(repoGroup.transactions.single.amount, 106.67);
      expect(repoGroup.reminders.single.amount, 213.33);

      a2.beginTurn();
      final p1 = a2.handleCommand('me pagaram 106,67 do jantar')!;
      expect(p1.route, 'split_settled_partial');
      expect(repoGroup.getActiveDebtors().single.amount, closeTo(106.66, 0.001));

      a2.beginTurn();
      final p2 = a2.handleCommand('recebi 106,66 do jantar')!;
      expect(p2.route, 'split_settled');
      expect(repoGroup.getActiveDebtors(), isEmpty);

      a2.beginTurn();
      expect(a2.handleCommand('desfaz')!.route, 'undo');
      expect(repoGroup.getActiveDebtors().single.amount, closeTo(106.66, 0.001));
    });
  });

  group('10.2 moedas e IR', () {
    test('lançamento em dólar guarda a cotação; o total é em reais', () {
      expect(Currencies.toBase(20, 5.42), 108.40);
      final t = FinancialTransaction(
          id: 'u', title: 'Uber NY', amount: 108.40, type: TransactionType.expense, category: 'transport', paymentMethod: 'credit_card',
          date: DateTime(2026, 10, 1), originalCurrency: 'USD', originalAmount: 20, exchangeRate: 5.42);
      final back = FinancialTransaction.fromJson(t.toJson());
      expect([back.originalCurrency, back.originalAmount, back.exchangeRate, back.amount], ['USD', 20, 5.42, 108.40]);
      expect(Currencies.format('USD', 20), 'US\$ 20,00');
    });

    test('relatório do IR: saúde e educação dedutíveis, rendimentos por fonte', () {
      FinancialTransaction t(String title, double v, String cat, TransactionType type, int year) => FinancialTransaction(
          id: '$title$year', title: title, amount: v, type: type, category: cat, paymentMethod: 'pix', date: DateTime(year, 5, 10));
      final r = TaxReport.build([
        t('Consulta', 300, 'health', TransactionType.expense, 2026),
        t('Faculdade', 900, 'education', TransactionType.expense, 2026),
        t('Mercado', 500, 'supermarket', TransactionType.expense, 2026),
        t('Salário Empresa X', 5000, 'salary', TransactionType.income, 2026),
        t('Consulta', 999, 'health', TransactionType.expense, 2025),
      ], 2026);
      expect([r.healthTotal, r.educationTotal, r.incomeTotal], [300, 900, 5000]);
      final csv = r.toCsv();
      expect(csv.startsWith('﻿'), isTrue);
      expect(csv, contains('Saúde;10/05/2026;Consulta;300,00'));
      expect(csv, isNot(contains('Mercado')));
    });
  });

  group('10.2 widget e atalhos', () {
    test('link do atalho: aba, frase e voz', () {
      final link = KrezioRoutes.asRoute(Uri.parse('krezio://app/chat?frase=gastei%2030%20no%20uber'));
      expect(KrezioRoutes.tabFor(link!.path), 2);
      expect(KrezioRoutes.phraseIn(link), 'gastei 30 no uber');
      expect(KrezioRoutes.wantsVoice(Uri.parse('/chat?voz=1')), isTrue);
      expect(KrezioRoutes.phraseIn(Uri.parse('/chat')), isNull);
    });

    test('o widget mostra o saldo do mês', () {
      final repo = emptyRepo();
      final now = DateTime.now();
      repo.addTransaction(FinancialTransaction(
          id: 's', title: 'Salário', amount: 3000, type: TransactionType.income, category: 'salary', paymentMethod: 'pix', date: now));
      repo.addTransaction(FinancialTransaction(
          id: 'm', title: 'Mercado', amount: 500, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: now));
      final v = HomeWidgetSync.values(repo);
      expect(v.balance, 'R\$ 2.500,00');
      expect(v.detail, contains('Saídas R\$ 500,00'));
    });
  });

  group('10.3 melhorias solicitadas (PDF Itaú, Cofrinho, Máscara BRL, Filtros, Lembretes e Notificações)', () {
    test('PDF Itaú: extrai lançamentos com sinal após valor, D/C e ignora linhas de saldo', () {
      const itauPdfText = '''
ITAÚ UNIBANCO S.A. - EXTRATO DE CONTA CORRENTE
Período: 01/10/2026 a 31/10/2026
01/10 SALDO ANTERIOR 1.500,00
05/10 REMUNERACAO SALARIO 4.500,00 C
10/10 PIX TRANSF JOAO SILVA -150,00
12/10 RSHOP-MERCADO EXTRA 12/10 245,90 -
18/10 SISPAG CONTA LUZ 180,45 D
31/10 S A L D O 5.423,65
''';
      final entries = StatementImport.parsePdfText(itauPdfText);
      expect(entries.length, 4);
      expect(entries[0].description, 'Remuneracao Salario');
      expect(entries[0].amount, 4500.00);
      expect(entries[0].date, DateTime(2026, 10, 5));

      expect(entries[1].description, 'Pix Transf Joao Silva');
      expect(entries[1].amount, -150.00);

      expect(entries[2].description, 'Rshop-mercado Extra');
      expect(entries[2].amount, -245.90);

      expect(entries[3].description, 'Sispag Conta Luz');
      expect(entries[3].amount, -180.45);

      // Also test PDF binary stream extraction with Tj/Td operators
      const rawPdf = '%PDF-1.4\nstream\nBT\n(10/10/2026 PIX MERCADO -89,90) Tj\nET\nendstream\n%%EOF';
      final fromBytes = StatementImport.parsePdfBytes(latin1.encode(rawPdf));
      expect(fromBytes.single.amount, -89.90);
      expect(fromBytes.single.description, 'Pix Mercado');
    });

    test('Máscara de moeda BRL: preenche a partir dos centavos', () {
      const formatter = BrlCurrencyInputFormatter();
      TextEditingValue type(String old, String typed) =>
          formatter.formatEditUpdate(TextEditingValue(text: old), TextEditingValue(text: typed));

      expect(type('', '4').text, '0,04');
      expect(type('0,04', '0,045').text, '0,45');
      expect(type('0,45', '0,450').text, '4,50');
      expect(type('4,50', '4,500').text, '45,00');
      final res4000 = type('', '400000');
      expect(res4000.text, '4.000,00');
      expect(Money.parse(res4000.text), 4000.00);

      final res5090 = type('', '50,90');
      expect(res5090.text, '50,90');
      expect(Money.parse(res5090.text), 50.90);

      // Backspace tira o último dígito, inclusive quando cai na vírgula.
      expect(type('45,00', '45,0').text, '4,50');
      expect(type('4.000,00', '4.00000').text, '400,00');
      expect(type('0,04', '0,0').text, '');
    });

    test('Cofrinho: aplicar valor retira do saldo líquido total como despesa', () {
      final repo = emptyRepo();
      final now = DateTime.now();
      repo.addTransaction(FinancialTransaction(
        id: 'sal-1',
        title: 'Salário',
        amount: 4000,
        type: TransactionType.income,
        category: 'salary',
        paymentMethod: 'pix',
        date: now,
      ));
      expect(repo.totalBalance, 4000);

      repo.addGoal(FinancialGoal(
        id: 'cof-1',
        title: 'Reserva Viagem',
        targetAmount: 2000,
      ));
      repo.contributeToGoal('cof-1', 500, recordExpense: true);

      expect(repo.goals.single.savedAmount, 500);
      expect(repo.totalBalance, 3500);
      expect(repo.monthExpense, 500);
      expect(repo.transactions.any((t) => t.type == TransactionType.expense && t.amount == 500), isTrue);
    });

    test('StatementQuery: filtra pela margem de valor mínimo e máximo', () {
      final now = DateTime(2026, 10, 20);
      final txs = [
        FinancialTransaction(id: '1', title: 'Café', amount: 15, type: TransactionType.expense, category: 'leisure', paymentMethod: 'pix', date: now),
        FinancialTransaction(id: '2', title: 'Mercado', amount: 180, type: TransactionType.expense, category: 'supermarket', paymentMethod: 'pix', date: now),
        FinancialTransaction(id: '3', title: 'Aluguel', amount: 1500, type: TransactionType.expense, category: 'housing', paymentMethod: 'pix', date: now),
      ];
      final filtered = StatementQuery.apply(
        txs,
        const StatementFilter(minAmount: 50, maxAmount: 500),
        now: now,
      );
      expect(filtered.map((t) => t.id), ['2']);
    });

    test('Lembretes e Contas a Receber: cores verde (+) e vermelho (-)', () {
      final receivable = FinancialReminder(
        id: 'r1',
        title: 'João me deve',
        amount: 150,
        targetDate: DateTime(2026, 10, 25),
        type: ReminderType.loanReceivable,
      );
      final bill = FinancialReminder(
        id: 'r2',
        title: 'Conta de Luz',
        amount: 180,
        targetDate: DateTime(2026, 10, 25),
        type: ReminderType.billPayment,
      );
      expect(receivable.amountPrefix, '+ ');
      expect(receivable.amountColor, KrezioColors.emeraldGreen);
      expect(bill.amountPrefix, '- ');
      expect(bill.amountColor, KrezioColors.budgetOver);
    });

    test('Easter egg 5 cliques em versão do app e NotificationService', () {
      final now = DateTime(2026, 10, 20, 10, 0);
      for (var i = 0; i < 4; i++) {
        expect(EnvironmentConfig.registerEasterEggTap(now: now.add(Duration(milliseconds: i * 100))), isFalse);
      }
      expect(EnvironmentConfig.registerEasterEggTap(now: now.add(const Duration(milliseconds: 400))), isTrue);

      final repo = emptyRepo();
      repo.addReminder(FinancialReminder(
        id: 'rem-1',
        title: 'Pagar Internet',
        amount: 120,
        targetDate: now,
        type: ReminderType.billPayment,
      ));
      final notifService = NotificationService(repo);
      final pending = notifService.evaluatePendingNotifications(now: now);
      expect(pending.length, 2); // 1 due bill + 1 daily transaction logging reminder
    });
  });
}
