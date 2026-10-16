import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/models/financial_goal.dart';

import '../analytics_test.dart' as a;
import 'chaos_r3_support.dart';

/// As perguntas de análise do dono, numa conversa com 6 meses de histórico.
void main() {
  test('analytics chat probe', () async {
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    const scripts = [
      ['posso comprar um notebook de 2000 reais?'],
      ['posso comprar uma moto de 18 mil?'],
      ['posso comprar uma tv de 6000 em 10x?'],
      ['posso comprar um iphone?', '8000'],
      ['como estou me saindo com base nas nossas metas?'],
      ['o que eu devo cortar de gastos?'],
      ['o que eu poderia fazer para economizar mais?'],
      ['o que eu devo cortar de gastos?', 'se eu economizar nisso, em quanto tempo vou ter dinheiro para comprar um notebook de 2000 reais?'],
      ['se eu cortar o delivery, em quanto tempo consigo comprar um carro de 30 mil?', 'sim'],
      ['se eu guardar 500 por mês, em quanto tempo consigo comprar uma moto de 15 mil?'],
      ['vou bater minhas metas?'],
      ['onde eu to gastando demais?'],
    ];
    for (final script in scripts) {
      final repo = a.repo(goals: [
        FinancialGoal(id: 'g1', title: 'Viagem', targetAmount: 10000, savedAmount: 3000, targetDate: DateTime(2027, 8, 31), createdAt: DateTime(2026, 7, 16)),
        FinancialGoal(id: 'g2', title: 'Carro', targetAmount: 60000, savedAmount: 1000, targetDate: DateTime(2027, 4, 30), createdAt: DateTime(2026, 6, 16)),
      ]);
      final sim = Sim3(engine, repo, now: () => a.now);
      final out = StringBuffer('AC|${script.first}\n');
      for (final line in script) {
        final r = sim.send(line);
        out.write('  > $line\n    [${r.route}] ${r.text.replaceAll('\n', '\n      ')}\n');
      }
      // ignore: avoid_print
      print(out);
    }
  });
}
