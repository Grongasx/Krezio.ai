import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'conversation_probe_test.dart' show ChatSim;

void main() {
  test('holdout', () async {
    SharedPreferences.setMockInitialValues({});
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    final convs = <List<String>>[
      ['desembolsei 230 no conserto da geladeira no pix'],
      ['a mensalidade do pilates saiu 180 no débito'],
      ['vendi minha bike por 900 no pix'],
      ['o inquilino transferiu o aluguel, 1350 no pix'],
      ['doei 50 pra campanha do agasalho no pix'],
      ['paguei o pedágio, 12,40 no débito'],
      ['torrei uns 60 conto no bar ontem no pix'],
      ['me reembolsaram 45 da farmácia no pix'],
      ['gastei 80 no açougue no pix', 'o açougue na real foi 85'],
      ['gastei 80 no açougue no pix', 'deu 85 o açougue'],
      ['gastei 80 no açougue no pix', 'gastei 40 na feira no pix', 'apaga aquele do açougue', 'sim'],
      ['gastei 80 no açougue no pix', 'bota esse no débito'],
      ['gastei 80 no açougue no pix', 'esquece esse último', 'sim'],
      ['gastei 80 no açougue no pix', 'gastei 40 na feira no pix', 'o penúltimo foi 90'],
      ['quanto eu torrei com comida esse mês?'],
      ['qual foi a maior saída de setembro?'],
      ['to devendo alguma coisa?'],
      ['quanto a maria me deve?'],
      ['quanto eu gastei de ontem pra hoje?'],
      ['me mostra o que eu gastei no débito'],
      ['quanto sobra se eu pagar o aluguel?'],
      ['qual a média que eu gasto por dia?'],
      ['o mercado tá caro demais hoje em dia'],
      ['apaguei as luzes pra economizar e gastei 20 na padaria no pix'],
      ['meu pai pagou minha conta de luz de 150'],
      ['a conta de água veio 98 e paguei no pix'],
      ['comprei 3 cervejas de 8 no bar no pix'],
      ['emprestei 200 pro Lucas no pix'],
      ['gastei 50 no mercado no pix', 'e mais 30 na farmácia'],
      ['gastei 50 no mercado no pix', 'qual meu saldo?', 'desfaz'],
    ];
    var i = 0;
    for (final turns in convs) {
      final sim = ChatSim(engine, FinancialRepository());
      final base = sim.repo.transactions.length;
      final out = <String>[];
      for (final t in turns) {
        final r = sim.send(t);
        out.add('"$t" -> ${r.toString().replaceAll('\n', ' ')}');
      }
      final saved = sim.repo.transactions.take(sim.repo.transactions.length - base < 0 ? 0 : 3).map((t) => '${t.title}|${t.amount}|${t.type.name}|${t.category}|${t.paymentMethod}').join(' ; ');
      print('HO#${++i} ${out.join('  ⏎  ')}\n      REPO(Δ${sim.repo.transactions.length - base}): $saved');
    }
  });
}
