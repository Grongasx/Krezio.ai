import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

import 'chaos_r3_support.dart';

/// Sonda dos defeitos que sobraram da rodada de feedback (só imprime).
void main() {
  test('r5 probe', () async {
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    const scripts = [
      ['dia primeiro paguei 90 de net no boleto'],
      ['comprei um guarda chuva de 40 no pix', 'muda', 'pra 45'],
      ['comprei 2 pizzas de 40 cada uma e 3 refris de 5 cada um no pix'],
      ['comprei um notebook de 4200 em 12 meses no cartão'],
      ['paguei 300 da mensalidade do inglês no pix'],
      ['comprei um ps5 por 4000 no pix'],
      ['comprei creatina por 120 e coqueteleira por 30 os dois no débito'],
      ['comprei um tênis por 400 e uma camiseta por 80 no crédito em 2x cada um e almocei por 35 no pix tudo ontem'],
    ];
    for (final script in scripts) {
      final repo = FinancialRepository();
      repo.replaceAllFromCloud(transactions: [], reminders: [], budgets: repo.budgets.toList(), goals: [], categoryOverrides: {});
      final sim = Sim3(engine, repo);
      final out = StringBuffer();
      for (final line in script) {
        final r = sim.send(line);
        out.write('  > $line\n    [${r.route}] ${r.text.replaceAll('\n', ' ⏎ ')}\n');
      }
      final saved = repo.transactions
          .map((t) => '${t.title}:${t.amount}:${t.category}:${t.paymentMethod}:${t.installments ?? 1}x:${t.isRecurrent ? 'rec' : ''}:${t.date.day}/${t.date.month}')
          .join(' | ');
      // ignore: avoid_print
      print('R5|${script.first}\n$out  SAVED: $saved\n');
    }
  });
}
