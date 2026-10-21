import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

import 'chaos_r3_support.dart';

/// Terceira onda: gíria, erro de digitação, sem acento, frases longas.
/// Formato "frase => rota esperada (prefixo)". Só imprime e conta.
const cases = <String, String>{
  'e ai cesar, oq tem pra hj?': 'planner:agenda',
  'oq vence essa semana??': 'report:bills|planner:agenda',
  'tem boleto vencendo amanha': 'planner:agenda|report:bills',
  'bom dia, como eu to de grana': 'planner:situation',
  'to bem de dinheiro esse mes?': 'planner:situation|planner:profit',
  'quem ta me devendo esse mes': 'planner:charge|report:debtors',
  'quem eu tenho q cobrar': 'planner:charge',
  'fiz um emprestimo no banco de 5 mil em 24x': 'planner:debt',
  'peguei 300 emprestado do meu primo, devolvo semana que vem': 'planner:debt',
  'to devendo 800 pra minha mae': 'planner:debt',
  'quanto eu to devendo?': 'planner:my_debts',
  'paguei mais uma parcela': 'planner:installment_paid|planner:my_debts|ask',
  'quero sair do vermelho': 'planner:payoff',
  'como faço pra baixar o extrato do itau': 'help',
  'da pra importar extrato do banco?': 'help',
  'qnto posso investir esse mes': 'planner:invest',
  'quanto eu deveria guardar todo mes': 'planner:budget',
  'quero juntar grana pra comprar uma casa': 'planner:goal',
  'quero trocar de carro ano que vem, um de 60 mil': 'planner:goal',
  'quero comprar um iphone de 8 mil, em quantos meses consigo?': 'planner:goal',
  'me ajuda a montar um orcamento': 'planner:budget',
  'divide meu salario pra mim': 'planner:budget',
  'meu salario e 3500, monta um plano': 'planner:budget',
  'o que e selic': 'planner:knowledge',
  'cheque especial é ruim?': 'planner:knowledge',
  'tô quebrado': 'planner:no_money',
  'tô apertado esse mês': 'planner:no_money',
  'da pra sair pra uma pizza hoje?': 'planner:can_go_out',
  'me lembra de pagar a luz dia 10': 'planner:reminder',
  'me avisa pra pagar o condominio em 5 dias': 'planner:reminder',
  'como foi minha semana': 'planner:week',
  'to ansioso com as contas': 'planner:feelings',
  'obrigadao, ajudou demais': 'smalltalk',
};

void main() {
  test('natural probe 3', () async {
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    var ok = 0;
    for (final e in cases.entries) {
      final repo = FinancialRepository();
      final sim = Sim3(engine, repo);
      // Uma dívida em parcelas existe, para "paguei mais uma parcela".
      if (e.key.contains('parcela')) {
        sim.send('fiz um empréstimo de 3000 em 12x de 300 todo dia 15');
      }
      final r = sim.send(e.key);
      final pass = e.value.split('|').any((p) => r.route.startsWith(p));
      if (pass) ok++;
      // ignore: avoid_print
      print('N3|${pass ? 'OK ' : 'FAIL'}|${e.key} => [${r.route}] ${r.text.replaceAll('\n', ' ⏎ ').substring(0, r.text.length.clamp(0, 140))}');
    }
    // ignore: avoid_print
    print('N3TOTAL $ok/${cases.length}');
  });
}
