import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';

void main() {
  test('multi probe', () async {
    final e = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    for (final s in [
      'comprei 2 pizzas de 40 cada uma e 3 refris de 5 cada um no pix',
      'comprei 2 pizzas de 40 e 3 refris de 5 no pix',
      'comprei pizza de 40 e refri de 5 no pix',
      'comprei pizza de 40 e 3 refris de 5 no pix',
      'comprei pizza de 40 e refris de 5 no pix',
      'comprei 2 pizzas de 40 e refri de 5 no pix',
      'comprei 2 pizzas por 40 cada uma e 3 refris por 5 cada um no pix',
      'comprei 2 pizzas de 40 cada e 3 refris de 5 cada no pix',
      'comprei 3 refris de 5 cada um no pix',
      'comprei um tênis por 400 e uma camiseta por 80 no crédito em 2x cada um e almocei por 35 no pix tudo ontem',
      'dia primeiro paguei 90 de net no boleto',
      'dia 1 paguei 90 de net no boleto',
      'paguei 90 de internet no boleto dia primeiro',
      'no dia primeiro paguei 90 da internet no boleto',
      'dia 1º paguei 90 de net no boleto',
      'comprei um ps5 por 4000 no pix',
    ]) {
      final m = e.parseMulti(s);
      // ignore: avoid_print
      print('MP|$s\n   multi=${m.map((d) => '${d.description}:${d.amount}:${d.paymentMethod}:${d.installments}:${d.category}:${d.dateOffsetDays}').join(' | ')}'
          '\n   single=${e.parse(s).description}:${e.parse(s).amount}:${e.parse(s).category}:${e.parse(s).dateOffsetDays}:${e.parse(s).missingSlots}');
    }
  });
}
