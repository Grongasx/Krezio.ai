// Ferramenta de inspeção: roda cenários de um arquivo (um por linha, turnos
// separados por " ⏎ ") no ChatSim com o seedA da bateria r3 e imprime rota,
// resposta e lançamentos criados. Arquivo em PROBE_FILE (padrão:
// test/_qa/phrases.txt). Não é teste de regressão.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_probe_test.dart' show ChatSim;
import 'conversation_r3_probe_test.dart' show seedA;

void main() {
  test('phrase probe', () async {
    SharedPreferences.setMockInitialValues({});
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    final file = Platform.environment['PROBE_FILE'] ?? 'test/_qa/phrases.txt';
    for (final line in File(file).readAsLinesSync()) {
      if (line.trim().isEmpty || line.startsWith('#')) continue;
      final repo = FinancialRepository();
      seedA(repo);
      final before = repo.transactions.map((t) => t.id).toSet();
      final sim = ChatSim(engine, repo);
      final out = <String>[];
      for (final turn in line.split(' ⏎ ')) {
        final r = sim.send(turn);
        out.add('[${r.route}] ${r.text.replaceAll('\n', ' ⏎ ')}');
      }
      final created = repo.transactions.where((t) => !before.contains(t.id)).map((t) =>
          '${t.title} ${t.amount} ${t.category} ${t.paymentMethod} ${t.type.name} ${t.date.day}/${t.date.month}');
      // ignore: avoid_print
      print('PP| $line\n   => ${out.join('\n   => ')}\n   ++ [${created.join(' ; ')}]');
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
