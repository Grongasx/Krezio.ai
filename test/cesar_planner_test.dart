import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_planner.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_reminder.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

import '_qa/chaos_r3_support.dart';

/// Linguagem natural do dono do produto (2026-10-16): agenda, cobranças,
/// dívidas, ajuda, investir, metas e plano do salário — com várias falas.
void main() {
  late LocalFinancialNlpEngine engine;
  setUpAll(() async {
    engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
  });

  ({Sim3 sim, FinancialRepository repo}) chat() {
    final repo = FinancialRepository(); // dados de demonstração
    return (sim: Sim3(engine, repo), repo: repo);
  }

  String route(String line) => chat().sim.send(line).route;

  test('valores: "40 mil", "R\$ 3.000", dias e parcelas não são dinheiro', () {
    expect(CesarPlanner.money('40 mil'), 40000);
    expect(CesarPlanner.money('1,5 mil'), 1500);
    expect(CesarPlanner.money('R\$ 3.000'), 3000);
    expect(CesarPlanner.money('em 12x todo dia 15 de 250'), 250);
    expect(CesarPlanner.money('dentro de 4 dias'), isNull);
  });

  test('agenda do dia, da semana e do mês', () {
    for (final s in [
      'bom dia, me faça um resumo do que precisa ser feito hoje',
      'o que eu tenho pra hoje?',
      'o que temos para essa semana?',
      'quais são meus compromissos da semana',
      'o que eu preciso pagar esse mês?',
      'tem algum boleto pra pagar amanhã?',
      'tem conta atrasada?',
    ]) {
      expect(route(s), 'planner:agenda', reason: s);
    }
    expect(route('tenho alguma conta pra vencer?'), isNot('planner:agenda'), reason: 'sem dia: o relatório de contas');
  });

  test('quem cobrar e situação geral', () {
    expect(route('quem eu preciso cobrar esse mês'), 'planner:charge');
    expect(route('tem alguém atrasado comigo?'), 'planner:charge');
    for (final s in ['bom dia! como tá minha situação?', 'me atualiza das minhas finanças', 'resumo da semana']) {
      expect(route(s), 'planner:situation', reason: s);
    }
    expect(route('tô no lucro esse mês?'), 'planner:profit');
    expect(route('consigo pagar todas as contas esse mês?'), 'planner:can_pay');
  });

  test('dívida sem valor: pergunta, anota e avisa no prazo', () {
    final c = chat();
    expect(c.sim.send('acabei de fazer uma divida, preciso pagar ela dentro de 4 dias').route, 'planner:debt_ask');
    final r = c.sim.send('800 com o pedro');
    expect(r.route, 'planner:debt_created');
    final d = c.repo.reminders.firstWhere((x) => x.title == 'Dívida com Pedro');
    expect([d.amount, d.type], [800, ReminderType.billPayment]);
    final now = DateTime.now();
    expect(d.targetDate, DateTime(now.year, now.month, now.day).add(const Duration(days: 4)));
  });

  test('dívida em 12x todo dia 15: 12 lembretes e um "desfaz" tira tudo', () {
    final c = chat();
    final before = c.repo.reminders.length;
    c.sim.send('fiz uma divida dia 15, em 12x preciso pagar todo dia 15 agora');
    expect(c.sim.send('parcela de 250').route, 'planner:debt_created');
    final parcels = c.repo.reminders.where((r) => r.title.startsWith('Parcela')).toList();
    expect(parcels.length, 12);
    expect(parcels.every((p) => p.targetDate.day == 15 && p.amount == 250), isTrue);
    expect(c.sim.send('quanto eu devo?').text, contains('R\$ 3.000,00'));
    expect(c.sim.send('paguei a parcela do empréstimo').route, 'planner:installment_paid');
    expect(c.repo.reminders.where((r) => r.title.startsWith('Parcela') && !r.isCompleted).length, 11);
    c.sim.send('desfaz');
    c.sim.send('desfaz');
    expect(c.repo.reminders.length, before);
  });

  test('outras formas de dívida', () {
    final c = chat();
    expect(c.sim.send('devo 200 pro joão e vou pagar sexta').route, 'planner:debt_created');
    final d = c.repo.reminders.first; // os novos entram no começo
    expect(d.personName, 'João');
    expect(d.targetDate.weekday, DateTime.friday);
    expect(chat().sim.send('peguei 2 mil com meu pai, vou devolver em 3 meses').route, 'planner:debt_created');
    expect(chat().sim.send('fiz um empréstimo de 3000 em 12x de 300 todo dia 15').route, 'planner:debt_created');
  });

  test('cobrei e ele pagou tudo: quita a dívida e registra a entrada', () {
    final c = chat();
    final income = c.repo.monthIncome;
    expect(c.sim.send('cobrei o joão e ele pagou tudo').route, 'planner:debt_settled');
    expect(c.repo.getActiveDebtors(), isEmpty);
    expect(c.repo.monthIncome, income + 150);
  });

  test('como pegar o extrato no banco e outras ajudas', () {
    expect(chat().sim.send('como eu faço para pegar meu extrato no banco?').text, contains('Importar extrato'));
    expect(route('como cadastro um cartão de crédito?'), 'help');
    expect(route('tem como exportar meus dados?'), 'help');
    expect(route('o que você não sabe fazer?'), 'help');
  });

  test('quanto posso investir: sobra do mês e reserva de emergência, sem recomendar produto', () {
    final r = chat().sim.send('quanto eu posso investir esse mês');
    expect(r.route, 'planner:invest');
    expect(r.text, contains('reserva de emergência'));
    expect(chat().sim.send('onde eu invisto meu dinheiro?').text, contains('não posso recomendar produtos'));
    expect(route('o que é cdb?'), 'planner:knowledge');
    expect(route('tesouro direto vale a pena?'), 'planner:knowledge');
  });

  test('quero comprar um carro: pergunta o preço, faz o plano e cria a meta no "sim"', () {
    final c = chat();
    expect(c.sim.send('quero comprar um carro o mais rapido possivel? me ajude a economizar para isso').route, 'planner:goal_ask');
    final plan = c.sim.send('40 mil');
    expect(plan.route, 'planner:goal_plan');
    expect(plan.text, contains('R\$ 40.000,00'));
    expect(c.sim.send('em 2 anos').text, contains('24 meses'));
    expect(c.sim.send('sim').route, 'planner:goal_created');
    final goal = c.repo.goals.firstWhere((g) => g.title == 'Carro');
    expect(goal.targetAmount, 40000);
  });

  test('outras metas: moto até o fim do ano, viagem, quanto tempo, reserva', () {
    expect(chat().sim.send('consigo comprar uma moto de 15 mil até o fim do ano?').text, contains('**Moto** de R\$ 15.000,00'));
    expect(chat().sim.send('quero viajar pra europa ano que vem, quanto preciso guardar por mês?').text, contains('Viagem para Europa'));
    expect(route('quanto tempo pra eu juntar 20 mil?'), 'planner:goal_plan');
    expect(route('quero fazer uma reserva de emergência'), 'planner:goal_plan');
    expect(route('quero economizar 500 por mês'), 'planner:save_monthly');
  });

  test('definir gastos fixos e dividir o salário (fluxo completo)', () {
    final c = chat();
    expect(c.sim.send('vamos definir gastos fixos para minhas economias').route, 'planner:budget_ask_salary');
    expect(c.sim.send('sim').route, 'planner:budget_ask_fixed');
    final plan = c.sim.send('internet 100, escola 800');
    expect(plan.route, 'planner:budget_plan');
    expect(plan.text, allOf(contains('Internet'), contains('Escola'), contains('Guardar')));
    expect(c.sim.send('sim').route, 'planner:budget_applied');
    expect(c.repo.goals.any((g) => g.title == 'Reserva de emergência'), isTrue);
    expect(c.repo.preference('monthly_income'), '4500.00');
    // "ganho 5000 por mês, quanto devo guardar?" já entra com o salário.
    expect(chat().sim.send('ganho 5000 por mês, quanto devo guardar?').route, 'planner:budget_ask_fixed');
  });

  test('conversa: preocupação, agradecimento, piada, não ter dinheiro, sair pra jantar', () {
    expect(route('tô preocupado com dinheiro'), 'planner:feelings');
    expect(route('valeu, ajudou muito'), 'smalltalk');
    expect(route('me conta uma piada'), 'smalltalk');
    expect(route('tô sem dinheiro, o que eu faço?'), 'planner:no_money');
    expect(route('posso sair pra jantar hoje?'), 'planner:can_go_out');
  });

  test('"me lembra de pagar o aluguel dia 5" usa o último valor do aluguel', () {
    final c = chat();
    expect(c.sim.send('me lembra de pagar o aluguel dia 5').text, contains('R\$ 1.400,00'));
    expect(c.repo.reminders.first.targetDate.day, 5);
  });

  test('o fluxo não prende a conversa: outra frase segue normal', () {
    final c = chat();
    c.sim.send('quero comprar um carro o mais rapido possivel? me ajude a economizar para isso');
    expect(c.sim.send('gastei 50 no mercado no pix').route, 'saved');
  });
}
