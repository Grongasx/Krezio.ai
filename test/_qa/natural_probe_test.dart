import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

import 'chaos_r3_support.dart';

/// Linguagem natural variada (pedido do dono, 2026-10-16). Cada roteiro roda
/// num repositório com os dados de demonstração. Só imprime.
const scripts = <String, List<String>>{
  // Agenda / resumo do dia
  'agenda1': ['bom dia, me faça um resumo do que precisa ser feito hoje'],
  'agenda2': ['o que eu tenho pra hoje?'],
  'agenda3': ['tenho alguma coisa pra pagar hoje?'],
  'agenda4': ['o que temos para essa semana?'],
  'agenda5': ['quais são meus compromissos da semana'],
  'agenda6': ['boa noite cesar, como estão as coisas?'],
  'agenda7': ['me dá um panorama do mês'],
  // Cobrar / dívidas
  'cobrar1': ['quem eu preciso cobrar esse mês'],
  'cobrar2': ['quem tá me devendo?'],
  'cobrar3': ['tem alguém atrasado comigo?'],
  'cobrar4': ['quanto eu tenho pra receber?'],
  'divida1': ['acabei de fazer uma divida, preciso pagar ela dentro de 4 dias', '800 com o pedro'],
  'divida2': ['peguei 500 emprestado com meu irmão, pago em 4 dias'],
  'divida3': ['fiz uma divida dia 15, em 12x preciso pagar todo dia 15 agora', 'parcela de 250', 'quanto eu devo?', 'desfaz'],
  'divida4': ['fiz um empréstimo de 3000 em 12x de 300 todo dia 15'],
  'divida5': ['devo 200 pro joão e vou pagar sexta'],
  'divida6': ['quanto eu devo?', 'pra quem eu devo?'],
  // Ajuda / como fazer
  'ajuda1': ['como eu faço para pegar meu extrato no banco?'],
  'ajuda2': ['como importo meu extrato do nubank?'],
  'ajuda3': ['como funciona o app?'],
  'ajuda4': ['como cadastro um cartão de crédito?'],
  // Investir / sobrar
  'invest1': ['quanto eu posso investir esse mês'],
  'invest2': ['quanto dá pra guardar esse mês?'],
  'invest3': ['vale a pena investir agora?'],
  'invest4': ['onde eu invisto meu dinheiro?'],
  // Metas / compras grandes
  'meta1': ['quero comprar um carro o mais rapido possivel? me ajude a economizar para isso', '40 mil', 'sim'],
  'meta1b': ['quero comprar um carro o mais rapido possivel? me ajude a economizar para isso', '40 mil', 'em 2 anos', 'sim'],
  'meta2': ['quero comprar um carro de 40 mil, em quanto tempo consigo?'],
  'meta3': ['quero juntar 10 mil pra uma viagem até dezembro do ano que vem'],
  'meta4': ['to querendo trocar de celular, um de 3000, me ajuda a planejar'],
  // Planejamento do salário
  'plano1': ['vamos definir gastos fixos para minhas economias', 'sim', 'internet 100, escola 800', 'sim'],
  'plano1b': ['vamos definir gastos fixos para minhas economias', '6000', 'não', 'não'],
  'plano2': ['me ajuda a dividir meu salário'],
  'plano3': ['ganho 5000 por mês, quanto devo guardar?'],
  'plano4': ['monta um orçamento pra mim'],
  // Variadas
  'var1': ['to gastando demais?'],
  'var2': ['como foi meu mês?'],
  'var3': ['qual foi meu gasto com comida essa semana'],
  'var4': ['tô sem dinheiro, o que eu faço?'],
  'var5': ['posso sair pra jantar hoje?'],
  'var6': ['quanto eu gasto por mês com assinaturas'],
  'var7': ['me lembra de pagar o aluguel dia 5'],
  'var8': ['recebi meu salário'],
  'var9': ['obrigado cesar'],
  'var10': ['qual meu saldo?'],
};

void main() {
  test('natural probe', () async {
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    for (final e in scripts.entries) {
      final repo = FinancialRepository();
      final sim = Sim3(engine, repo);
      final before = repo.transactions.length;
      final beforeRem = repo.reminders.length;
      final out = StringBuffer('NP|${e.key}\n');
      for (final line in e.value) {
        final r = sim.send(line);
        out.write('  > $line\n    [${r.route}] ${r.text.replaceAll('\n', ' ⏎ ')}\n');
      }
      out.write('  Δtx=${repo.transactions.length - before} Δrem=${repo.reminders.length - beforeRem} pendente=${sim.active?.missingSlots}\n');
      // ignore: avoid_print
      print(out);
    }
  });
}
