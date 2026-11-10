import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
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

    test('Máscara de moeda BRL: 4000 vira 4.000,00 e 50,90 mantém centavos', () {
      const formatter = BrlCurrencyInputFormatter();
      final res4000 = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '4000'),
      );
      expect(res4000.text, '4.000,00');
      expect(Money.parse(res4000.text), 4000.00);

      final res5090 = formatter.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '50,90'),
      );
      expect(res5090.text, '50,90');
      expect(Money.parse(res5090.text), 50.90);
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
