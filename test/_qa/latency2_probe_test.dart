import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_planner.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

void main() {
  test('latency2', () {
    final planner = CesarPlanner(repository: FinancialRepository());
    for (var i = 0; i < 4; i++) {
      final sw = Stopwatch()..start();
      planner.start('cancela');
      // ignore: avoid_print
      print('LAT2| run $i: ${sw.elapsedMilliseconds}ms');
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < 200; i++) {
      RegExp(r'\b(?:o\s+que|oque|onde|em\s+que)\s+(?:eu\s+)?(?:devo|posso)\s+(?:cortar|reduzir)\b').hasMatch('cancela');
    }
    // ignore: avoid_print
    print('LAT2| 200 regex constructions: ${sw.elapsedMilliseconds}ms');
  });
}
