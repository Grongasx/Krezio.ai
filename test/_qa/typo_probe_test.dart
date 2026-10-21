import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/keyword_typo_corrector.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';

void main() {
  test('typo probe', () async {
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    for (final w in ['aluguell', 'uberr', 'framacia', 'interneet', 'onbus', 'dentsta', 'merkado', 'debitoo', 'bolto', 'salrio', 'gatei', 'gastie', 'paguie', 'pagei', 'recebei']) {
      // ignore: avoid_print
      print('TY| $w -> ${KeywordTypoCorrector.correctText(w)}');
    }
    for (final s in [
      'paguie 220 de aluguell no bolto',
      'gatei 19 no uberr no pix',
      'gastei 88 na framacia no debitoo',
      'pagei 95 de interneet',
      'gastie 13 no onbus',
      'paguie 180 no dentsta no pix',
      'gastei 22 no merkado ontem no pics',
      'recebei 3100 de salrio',
      'gastie 64 no açouge no pics',
    ]) {
      final d = engine.parse(s);
      // ignore: avoid_print
      print('TP| ${d.intent} ${d.amount} ${d.category} ${d.paymentMethod} miss=${d.missingSlots} desc=${d.description} | $s');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
