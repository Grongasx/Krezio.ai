import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';

import '_qa/chaos_r3_support.dart';
import 'analytics_test.dart' as a;

/// As perguntas de análise e previsão pelo chat, com 6 meses de histórico.
void main() {
  late LocalFinancialNlpEngine engine;
  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  Sim3 chat() => Sim3(
      engine,
      a.repo(goals: [
        FinancialGoal(id: 'g1', title: 'Viagem', targetAmount: 10000, savedAmount: 3000, targetDate: DateTime(2027, 8, 31), createdAt: DateTime(2026, 7, 16)),
        FinancialGoal(id: 'g2', title: 'Carro', targetAmount: 60000, savedAmount: 1000, targetDate: DateTime(2027, 4, 30), createdAt: DateTime(2026, 6, 16)),
      ]),
      now: () => a.now);

  test('posso comprar: simulação de 90 dias, à vista, parcelado e sem preço', () {
    final ok = chat().send('posso comprar um notebook de 2000 reais?');
    expect(ok.route, 'afford:yes');
    expect(ok.text, contains('400 cenários'));
    final no = chat().send('posso comprar uma moto de 18 mil?');
    expect(no.route, 'afford:no');
    expect(no.text, contains('Parcelado em'));
    expect(no.text, contains('Esperando até'));
    expect(no.text, isNot(contains('estouraria o orçamento')), reason: 'uma moto não é gasto do orçamento do mês');
    expect(chat().send('posso comprar uma tv de 6000 em 10x?').route, 'afford:yes', reason: 'a parcela é de R\$ 600');
    final c = chat();
    expect(c.send('posso comprar um iphone?').route, 'planner:purchase_ask');
    expect(c.send('8000').route, startsWith('afford:'));
  });

  test('como estou me saindo: nota, metas no ritmo e fora dele', () {
    final r = chat().send('como estou me saindo com base nas nossas metas?');
    expect(r.route, 'planner:goals_report');
    expect(r.text, contains('Nota'));
    expect(r.text, contains('✅ **Viagem**'));
    expect(r.text, contains('⚠️ **Carro**'));
    expect(chat().send('vou bater minhas metas?').route, 'planner:goals_report');
  });

  test('o que cortar: delivery e assinaturas, com o efeito nas metas', () {
    final r = chat().send('o que eu devo cortar de gastos?');
    expect(r.route, 'planner:cuts');
    expect(r.text, allOf(contains('**Delivery (iFood)**'), contains('**Assinaturas de streaming**'), contains('chega')));
    expect(chat().send('onde eu to gastando demais?').route, 'planner:cuts');
  });

  test('economizar mais: cortes, pague-se primeiro e orçamento estourado', () {
    final r = chat().send('o que eu poderia fazer para economizar mais?');
    expect(r.route, 'planner:save_more');
    expect(r.text, allOf(contains('Pague-se primeiro'), contains('dia 5')));
  });

  test('"se eu economizar nisso" usa os cortes da resposta anterior', () {
    final c = chat();
    c.send('o que eu devo cortar de gastos?');
    final r = c.send('se eu economizar nisso, em quanto tempo vou ter dinheiro para comprar um notebook de 2000 reais?');
    expect(r.route, 'planner:scenario');
    expect(r.text, contains('cortes que sugeri'));
    expect(r.text, contains('Sem mexer no saldo'));
  });

  test('cenário com corte nomeado vira meta no "sim"', () {
    final c = chat();
    final r = c.send('se eu cortar o delivery, em quanto tempo consigo comprar um carro de 30 mil?');
    expect(r.route, 'planner:scenario');
    expect(r.text, contains('Cortando Delivery'));
    expect(r.text, contains('adianta a compra'));
    expect(c.send('sim').route, 'planner:goal_created');
  });

  test('"se eu guardar 500 por mês" usa exatamente esse valor', () {
    final r = chat().send('se eu guardar 500 por mês, em quanto tempo consigo comprar uma moto de 15 mil?');
    expect(r.text, contains('Guardando R\$ 500,00 por mês'));
  });

  test('quanto posso investir: o fim do mês simulado, caso pessimista', () {
    final r = chat().send('quanto eu posso investir esse mês');
    expect(r.route, 'planner:invest');
    expect(r.text, contains('90% de chance'));
  });
}
