import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/analytics/financial_advisors.dart';

import '../analytics_test.dart' as a;

void main() {
  test('perf', () {
    final ctx = AnalysisContext(a.repo(), now: a.now);
    final sw = Stopwatch()..start();
    PurchaseAdvisor(ctx).evaluate(price: 18000);
    // ignore: avoid_print
    print('PERF compra-no: ${sw.elapsedMilliseconds} ms');
    sw.reset();
    ctx.forecast();
    // ignore: avoid_print
    print('PERF forecast90: ${sw.elapsedMilliseconds} ms');
    sw.reset();
    SavingsCoach(ctx).cuts();
    // ignore: avoid_print
    print('PERF cuts: ${sw.elapsedMilliseconds} ms');
  });
}
