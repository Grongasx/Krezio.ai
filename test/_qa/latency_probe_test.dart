import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/cesar_assistant.dart';
import 'package:krezio_ai/ai/cesar_planner.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';
import 'package:krezio_ai/backend/repositories/financial_repository.dart';

void main() {
  test('latency', () async {
    final engine = LocalFinancialNlpEngine.fromJsonString(await File('models/on_device/krezio_nlp_model.json').readAsString());
    final repo = FinancialRepository();
    final a = CesarAssistant(repository: repo, engine: engine);
    final planner = CesarPlanner(repository: repo);
    for (final s in [
      'apaga o anterior',
      'cancela',
      'gastei 50 no mercado no pix',
      'quanto gastei esse mês?',
      'ainda falta quitar 300 do empréstimo',
      'semana que vem tenho que depositar 200 pro meu irmão',
      'minha meta é gastar no máximo 800 no mercado',
    ]) {
      final sw = Stopwatch()..start();
      a.beginTurn();
      a.handleCommand(s);
      final c = sw.elapsedMilliseconds;
      sw.reset();
      a.handleQuestion(s);
      final q = sw.elapsedMilliseconds;
      sw.reset();
      planner.start(s);
      final p = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print('LAT| cmd=${c}ms q=${q}ms planner=${p}ms  $s');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
