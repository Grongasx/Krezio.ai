import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';

void main() {
  test('latency4', () async {
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    for (final s in ['gastei 50 no mercado no pix', 'cancela', 'comprei 2 pizzas de 40 cada uma e 3 refris de 5 cada um no pix']) {
      final times = <int>[];
      for (var i = 0; i < 8; i++) {
        final sw = Stopwatch()..start();
        engine.parse(s);
        times.add(sw.elapsedMilliseconds);
      }
      // ignore: avoid_print
      print('LAT4| $times  $s');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
