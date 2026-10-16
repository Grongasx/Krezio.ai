import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_transaction.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

import '_qa/chaos_r3_support.dart';

/// Defeitos que sobraram da rodada de feedback de 2026-10-16.
void main() {
  late LocalFinancialNlpEngine engine;
  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  List<FinancialTransaction> run(List<String> lines) {
    final repo = FinancialRepository();
    repo.replaceAllFromCloud(transactions: [], reminders: [], budgets: repo.budgets.toList(), goals: [], categoryOverrides: {});
    final sim = Sim3(engine, repo);
    for (final l in lines) {
      sim.send(l);
    }
    return repo.transactions.toList()..sort((a, b) => a.amount.compareTo(b.amount));
  }

  test('"dia primeiro paguei 90 de net no boleto": dia 1 e internet em moradia', () {
    final t = run(['dia primeiro paguei 90 de net no boleto']).single;
    final now = DateTime.now();
    final expected = now.day >= 1 ? DateTime(now.year, now.month, 1) : DateTime(now.year, now.month - 1, 1);
    expect(DateTime(t.date.year, t.date.month, t.date.day), expected);
    expect(t.category, 'housing');
    expect(t.paymentMethod, 'bank_slip');
  });

  test('"primeiro de outubro" também é dia 1', () {
    expect(engine.parse('paguei 50 de luz no pix no dia primeiro').dateOffsetDays,
        engine.parse('paguei 50 de luz no pix no dia 1').dateOffsetDays);
  });

  test('"2 pizzas de 40 cada uma e 3 refris de 5 cada um": 80 + 15, nada se perde', () {
    final t = run(['comprei 2 pizzas de 40 cada uma e 3 refris de 5 cada um no pix']);
    expect(t.map((x) => x.amount), [15, 80]);
    expect(t.map((x) => x.title), ['Refris', 'Pizza']);
    expect(t.every((x) => x.paymentMethod == 'pix'), isTrue);
  });

  test('"notebook de 4200 em 12 meses no cartão": crédito em 12x, não assinatura', () {
    final t = run(['comprei um notebook de 4200 em 12 meses no cartão']).single;
    expect([t.paymentMethod, t.installments, t.isRecurrent], ['credit_card', 12, false]);
    // Uma assinatura "por 12 meses" continua sendo assinatura.
    expect(engine.parse('assinei o plano anual da academia por 12 meses no cartão').isRecurrent, isTrue);
  });

  test('substantivo composto vira um nome só', () {
    expect(engine.parse('comprei um guarda chuva de 40 no pix').description, 'Guarda-chuva');
    expect(engine.parse('comprei um micro ondas de 600 no débito').description, 'Micro-ondas');
  });

  test('"ps5" é lazer, com nome legível', () {
    final t = run(['comprei um ps5 por 4000 no pix']).single;
    expect([t.title, t.category], ['PlayStation 5', 'leisure']);
  });

  test('"no crédito em 2x cada um" vale para os itens da frase', () {
    final t = run(['comprei um tênis por 400 e uma camiseta por 80 no crédito em 2x cada um e almocei por 35 no pix tudo ontem']);
    expect(t.length, 3);
    final tenis = t.firstWhere((x) => x.amount == 400);
    final camiseta = t.firstWhere((x) => x.amount == 80);
    final almoco = t.firstWhere((x) => x.amount == 35);
    expect([tenis.paymentMethod, tenis.installments], ['credit_card', 2]);
    expect([camiseta.paymentMethod, camiseta.installments], ['credit_card', 2]);
    expect(almoco.paymentMethod, 'pix');
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    expect(t.every((x) => x.date.day == yesterday.day), isTrue);
  });
}
