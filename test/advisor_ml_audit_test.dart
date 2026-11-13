import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_advisor.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixedNow = DateTime(2026, 11, 15, 14, 0);

  Future<FinancialRepository> emptyRepo() async {
    SharedPreferences.setMockInitialValues({});
    final repo = FinancialRepository();
    await repo.initialize();
    await repo.clearAllData();
    return repo;
  }

  FinancialTransaction tx({
    required String id,
    required String title,
    required double amount,
    required DateTime date,
    TransactionType type = TransactionType.expense,
    String category = 'leisure',
    bool isRecurrent = false,
  }) {
    return FinancialTransaction(
      id: id,
      title: title,
      amount: amount,
      date: date,
      type: type,
      category: category,
      paymentMethod: 'pix',
      isRecurrent: isRecurrent,
    );
  }

  group('Auditoria ML Sênior — Caminhos de Análise Automática (CesarAdvisor)', () {
    test('Caminho 1: Cold-start e histórico vazio nunca alucinam projeções ou cortes', () async {
      final repo = await emptyRepo();
      final advisor = CesarAdvisor(repository: repo, now: () => fixedNow);

      final insights = advisor.answer('analisa meus gastos');
      expect(insights?.route, 'advice:insights');
      expect(insights?.text, contains('Ainda não tenho lançamentos'));

      // Com apenas 10 dias de histórico, deve bloquear projeção e onde economizar
      repo.addTransaction(tx(
        id: 't1',
        title: 'Mercado',
        amount: 200,
        date: fixedNow.subtract(const Duration(days: 10)),
        category: 'supermarket',
      ));

      final proj = advisor.answer('como vou fechar o mês?');
      expect(proj?.route, 'advice:projection');
      expect(proj?.text, contains('Ainda não tenho dados suficientes'));

      final save = advisor.answer('onde posso economizar?');
      expect(save?.route, 'advice:where_to_save');
      expect(save?.text, contains('Ainda não tenho dados suficientes'));

      expect(advisor.unusualSpending(), isEmpty);
    });

    test('Caminho 2: Série histórica realista de 90 dias produz análise matemática concreta e rastreável', () async {
      final repo = await emptyRepo();
      // Meses anteriores (setembro e outubro): salário 5000, mercado 800/mês, lazer 300/mês
      for (final monthsAgo in [2, 1]) {
        final base = DateTime(fixedNow.year, fixedNow.month - monthsAgo, 5);
        repo.addTransaction(tx(
          id: 'sal-$monthsAgo',
          title: 'Salário',
          amount: 5000,
          date: base,
          type: TransactionType.income,
          category: 'salary',
          isRecurrent: true,
        ));
        repo.addTransaction(tx(
          id: 'mkt-$monthsAgo',
          title: 'Supermercado',
          amount: 800,
          date: base.add(const Duration(days: 5)),
          category: 'supermarket',
        ));
        repo.addTransaction(tx(
          id: 'laz-$monthsAgo',
          title: 'Cinema e Bar',
          amount: 300,
          date: base.add(const Duration(days: 10)),
          category: 'leisure',
        ));
      }

      // Mês atual (novembro até dia 15): salário 5000, mercado 800, lazer subiu para 900 (3x a média)
      repo.addTransaction(tx(
        id: 'sal-0',
        title: 'Salário',
        amount: 5000,
        date: DateTime(2026, 11, 5),
        type: TransactionType.income,
        category: 'salary',
        isRecurrent: true,
      ));
      repo.addTransaction(tx(
        id: 'mkt-0',
        title: 'Supermercado',
        amount: 800,
        date: DateTime(2026, 11, 8),
        category: 'supermarket',
      ));
      repo.addTransaction(tx(
        id: 'laz-0',
        title: 'Show e Restaurante',
        amount: 900,
        date: DateTime(2026, 11, 12),
        category: 'leisure',
      ));

      final advisor = CesarAdvisor(repository: repo, now: () => fixedNow);

      // 1. Onde economizar detecta Lazer crescendo acima da média
      final save = advisor.answer('onde posso economizar?');
      expect(save?.route, 'advice:where_to_save');
      expect(save?.text, contains('Lazer & Alimentação'));
      expect(save?.text, contains('900'));

      // 2. Projeção mostra a fórmula transparente (entradas - saídas - média diária * dias restantes)
      final proj = advisor.answer('como vou fechar o mês?');
      expect(proj?.route, 'advice:projection');
      expect(proj?.text, contains('Conta:'));
      expect(proj?.text, contains('dias restantes'));

      // 3. Insights gerais trazem saldo real e maior compra
      final insights = advisor.answer('o que você percebeu nos meus gastos?');
      expect(insights?.route, 'advice:insights');
      expect(insights?.text, contains('3.300')); // 5000 - (800 + 900) = 3300 sobrando
    });

    test('Caminho 3: Groundedness — simulação de corte sem histórico real daquele item nunca inventa economia', () async {
      final repo = await emptyRepo();
      repo.addTransaction(tx(
        id: 'mkt-1',
        title: 'Carrefour',
        amount: 600,
        date: fixedNow.subtract(const Duration(days: 40)),
        category: 'supermarket',
      ));
      repo.addTransaction(tx(
        id: 'mkt-2',
        title: 'Carrefour',
        amount: 600,
        date: fixedNow.subtract(const Duration(days: 5)),
        category: 'supermarket',
      ));

      final advisor = CesarAdvisor(repository: repo, now: () => fixedNow);
      final cutDelivery = advisor.answer('e se eu cortar o delivery?');
      expect(cutDelivery?.route, 'advice:cut');
      expect(cutDelivery?.text, contains('Não achei gastos com "delivery"'));
    });

    test('Caminho 4 (Probe de Vulnerabilidade ML): Histórico esparso de 2 pontos em 41 dias e anomalia de baixo valor', () async {
      final repo = await emptyRepo();
      // Apenas 1 gasto pequeno há 36 dias e 1 gasto pequeno hoje -> _daysOfData = 37 (>= 35), mas N = 2 amostras!
      repo.addTransaction(tx(
        id: 'old-1',
        title: 'Cafezinho',
        amount: 20,
        date: fixedNow.subtract(const Duration(days: 36)),
        category: 'leisure',
      ));
      repo.addTransaction(tx(
        id: 'new-1',
        title: 'Cafezinho',
        amount: 15,
        date: fixedNow.subtract(const Duration(days: 1)),
        category: 'leisure',
      ));

      final advisor = CesarAdvisor(repository: repo, now: () => fixedNow);
      final unusual = advisor.unusualSpending();
      final save = advisor.answer('onde posso economizar?');

      // Documentando o comportamento atual para o relatório de auditoria
      // ignore: avoid_print
      print('[AUDIT] unusual count com R\$ 15 vs média R\$ 5 (span 37d, N=2): ${unusual.length}');
      if (unusual.isNotEmpty) {
        // ignore: avoid_print
        print('[AUDIT] unusual text: ${unusual.first.text}');
      }
      // ignore: avoid_print
      print('[AUDIT] whereToSave com N=2 amostras em 37 dias: ${save?.text}');

      expect(save, isNotNull);
    });
  });
}
