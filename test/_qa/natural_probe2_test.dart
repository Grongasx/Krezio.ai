import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

import 'chaos_r3_support.dart';

/// Segunda onda: variações livres. Só imprime.
const lines = <String>[
  // agenda / rotina
  'cesar o que tem pra fazer hoje',
  'tem algum boleto pra pagar amanhã?',
  'me fala o que vence essa semana',
  'o que eu preciso pagar esse mês?',
  'tem conta atrasada?',
  'bom dia! como tá minha situação?',
  'resumo da semana',
  'me atualiza das minhas finanças',
  // cobrança / empréstimos
  'o joão ainda me deve?',
  'emprestei 300 pra maria, ela paga dia 30',
  'a maria me pagou 100',
  'quem me deve mais?',
  'cobrei o joão e ele pagou tudo',
  // dívidas
  'tô devendo 1500 no cartão',
  'parcelei uma geladeira em 10x de 280, vence todo dia 20',
  'peguei 2 mil com meu pai, vou devolver em 3 meses',
  'paguei a parcela do empréstimo',
  'quanto falta pra eu quitar minhas dívidas?',
  'tenho dívida?',
  // dinheiro / saúde financeira
  'quanto eu tenho?',
  'tô no lucro esse mês?',
  'quanto sobrou do salário?',
  'consigo pagar todas as contas esse mês?',
  'vai dar pra pagar o aluguel?',
  'minha situação tá boa?',
  'to gastando mais do que ganho?',
  'qual categoria eu mais gasto?',
  'quanto eu gastei de ifood esse mês',
  'quanto foi de uber na semana passada',
  'gastei muito com mercado?',
  // planejamento
  'quero economizar 500 por mês',
  'me ajuda a juntar dinheiro',
  'quero fazer uma reserva de emergência',
  'quanto preciso ter de reserva?',
  'quero viajar pra europa ano que vem, quanto preciso guardar por mês?',
  'consigo comprar uma moto de 15 mil até o fim do ano?',
  'quanto tempo pra eu juntar 20 mil?',
  'quero quitar meu cartão o quanto antes',
  'faz um plano pra eu sair das dívidas',
  // investimentos / conhecimento
  'o que é cdb?',
  'tesouro direto vale a pena?',
  'o que é reserva de emergência?',
  'como funciona juros do cartão?',
  // app / ajuda
  'como apago um lançamento?',
  'como mudo a categoria de um gasto?',
  'como vejo meus gastos do mês passado?',
  'você consegue ler meu extrato?',
  'o que você não sabe fazer?',
  'como coloco uma meta?',
  'tem como exportar meus dados?',
  // conversa
  'tô preocupado com dinheiro',
  'valeu, ajudou muito',
  'você é uma ia?',
  'qual seu nome?',
  'me conta uma piada',
];

void main() {
  test('natural probe 2', () async {
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    for (final line in lines) {
      final repo = FinancialRepository();
      final sim = Sim3(engine, repo);
      final tx = repo.transactions.length, rem = repo.reminders.length;
      final r = sim.send(line);
      // ignore: avoid_print
      print('N2|$line\n    [${r.route}] ${r.text.replaceAll('\n', ' ⏎ ')}\n    Δtx=${repo.transactions.length - tx} Δrem=${repo.reminders.length - rem}');
    }
  });
}
