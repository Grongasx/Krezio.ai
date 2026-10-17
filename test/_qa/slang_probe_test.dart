import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';

void main() {
  test('slang probe', () async {
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    for (final s in [
      'soltei 25 pro cara do lava rápido em espécie',
      'o rango de hoje saiu 34 no débito',
      'queimei 45 no happy hour ontem no pix',
      'paguei 16 de pedágio no dinheirinho',
      'peguei o mototáxi, 8 reais no dinheiro',
      'gastei 15 mangos no açaí no pix',
      'derreti 300 no shopping no crédito à vista',
      'detonei 80 no rolê de sábado no pix',
      'paguei 12 na padoca no débito',
      'queimei a mão no fogão',
      'soltei o cachorro no parque',
      'gastei 30 pratas no busão',
    ]) {
      final d = engine.parse(s);
      // ignore: avoid_print
      print('SL| ${d.intent} ${d.amount} ${d.category} ${d.paymentMethod} d=${d.dateOffsetDays} miss=${d.missingSlots} desc=${d.description} | $s');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
