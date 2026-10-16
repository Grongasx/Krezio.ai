import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

void main() {
  test('latency3', () async {
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    for (var round = 0; round < 3; round++) {
      final repo = FinancialRepository();
      final a = CesarAssistant(repository: repo, engine: engine);
      final total = Stopwatch()..start();
      for (final s in ['gastei 50 no mercado no pix', 'não, foi 45', 'apaga o anterior', 'quanto gastei esse mês?', 'cancela']) {
        final sw = Stopwatch()..start();
        a.beginTurn();
        a.handleCommand(s);
        final c = sw.elapsedMilliseconds;
        sw.reset();
        a.handleQuestion(s);
        final q = sw.elapsedMilliseconds;
        sw.reset();
        engine.parse(s);
        final e = sw.elapsedMilliseconds;
        // ignore: avoid_print
        print('LAT3| r$round cmd=${c} q=${q} parse=${e}  $s');
      }
      // ignore: avoid_print
      print('LAT3| round $round total ${total.elapsedMilliseconds}ms');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
