import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/local_nlp_engine.dart';

/// Bateria diagnóstica do novo XAI / NLP para "perguntas sem intent"
/// (saudações, fora de domínio, dúvidas conceituais, interrogações ambíguas
/// com palavras-gatilho, hipóteses/negações e ruído 100% OOV).
void main() {
  late LocalFinancialNlpEngine engine;

  setUpAll(() {
    final jsonStr = File('models/on_device/krezio_nlp_model.json').readAsStringSync();
    engine = LocalFinancialNlpEngine.fromJsonString(jsonStr);
  });

  List<NeuralThoughtTrace> runGroup(String groupName, List<String> phrases) {
    final traces = <NeuralThoughtTrace>[];
    final buf = StringBuffer('\n--- $groupName (${phrases.length} casos) ---\n');
    for (final p in phrases) {
      final trace = engine.inspect(p);
      traces.add(trace);
      final recordable = LocalFinancialNlpEngine.isRecordable(trace.draft);
      final mlIntent = trace.intentModel.predictedLabel;
      final conf = (trace.intentModel.confidence * 100).toStringAsFixed(1);
      final margin = (trace.intentModel.margin * 100).toStringAsFixed(1);
      final ent = trace.intentModel.normalizedEntropy.toStringAsFixed(2);
      final hit = (trace.vocabHitRate * 100).toStringAsFixed(0);
      final diff = mlIntent != trace.draft.intent ? 'OVERRIDE($mlIntent->${trace.draft.intent})' : 'ML=FINAL';
      final topXai = trace.intentModel.topContributions
          .take(2)
          .map((c) => '${c.token}:${c.contribution >= 0 ? '+' : ''}${c.contribution.toStringAsFixed(2)}')
          .join(', ');

      buf.writeln(
        '"$p" | ML=$mlIntent ($conf%, Δp=$margin%, H=$ent, zeroVec=${trace.intentModel.isZeroVectorFallback})'
        ' | Vocab=$hit% (${trace.activeFeatures.length}in/${trace.oovNgrams.length}oov)'
        ' | $diff | Draft=${trace.draft.intent} recordable=$recordable missing=${trace.missingSlots}'
        ' | XAI=[$topXai]',
      );

      // Invariantes XAI e proteção contra auto-gravação sem intent.
      expect(trace.intentModel.margin, inInclusiveRange(0.0, 1.0), reason: p);
      expect(trace.intentModel.normalizedEntropy, inInclusiveRange(0.0, 1.0), reason: p);
      expect(trace.vocabHitRate, inInclusiveRange(0.0, 1.0), reason: p);
      expect(
        recordable && const {'expense', 'income', 'transfer'}.contains(trace.draft.intent),
        isFalse,
        reason: '"$p" não deve virar lançamento gravável automaticamente',
      );
    }
    // ignore: avoid_print
    print(buf.toString());
    return traces;
  }

  group('Bateria XAI/NLP — Perguntas sem Intent', () {
    test('1. Saudações e chitchat não geram lançamento', () {
      final traces = runGroup('Saudação/Chitchat', const [
        'oi?',
        'tudo bem?',
        'cesar?',
        'e agora?',
        'o que você faz?',
        'posso te fazer uma pergunta?',
      ]);
      for (final t in traces) {
        expect(t.draft.intent, 'unknown');
        expect(t.parsedAmount, isNull);
      }
    });

    test('2. Perguntas fora de domínio ficam em unknown sem valor', () {
      final traces = runGroup('Fora de Domínio', const [
        'qual o sentido da vida?',
        'vai chover hoje?',
        'que horas são?',
        'qual a capital da frança?',
        'como faço café?',
      ]);
      for (final t in traces) {
        expect(t.draft.intent, 'unknown');
        expect(t.parsedAmount, isNull);
      }
    });

    test('3. Dúvidas conceituais/comparativas são barradas para unknown (sem falso rascunho)', () {
      final traces = runGroup('Conceitual/Dúvida', const [
        'o que é selic?',
        'pix cai na hora?',
        'cartão de crédito vale a pena?',
        'uber ou ônibus?',
        'por que o dólar subiu?',
        'como funciona o cofrinho?',
      ]);
      for (final t in traces) {
        expect(t.draft.intent, 'unknown', reason: t.rawText);
        expect(LocalFinancialNlpEngine.isRecordable(t.draft), isFalse);
      }
    });

    test('4. Interrogações ambíguas com triggers não abrem rascunho falso nem gravam', () {
      final traces = runGroup('Ambígua c/ Trigger', const [
        'mercado?',
        '50 reais?',
        'pix do joao?',
        'supermercado no pix?',
        'salario dia 5?',
        'netflix 55 no credito?',
      ]);
      // Etapa 1 + 3: perguntas sem valor e sem verbo de ação ficam em unknown;
      // "netflix 55 no credito?" (com valor) exige confirmação explícita [confirm].
      expect(traces[0].vocabHitRate, 1.0); // mercado?
      expect(traces[0].draft.intent, 'unknown');
      expect(traces[2].draft.intent, 'unknown'); // pix do joao?
      expect(traces[3].draft.intent, 'unknown'); // supermercado no pix?
      expect(traces[4].draft.intent, 'unknown'); // salario dia 5?
      expect(traces[5].missingSlots, contains('confirm'));
      for (final t in traces) {
        expect(LocalFinancialNlpEngine.isRecordable(t.draft), isFalse);
      }
    });

    test('5. Hipóteses e negações em pergunta são barradas ou tratadas como query', () {
      final traces = runGroup('Hipótese/Negação', const [
        'e se eu gastar 200 hoje?',
        'eu gastei no mercado ontem?',
        'não paguei o boleto ainda?',
      ]);
      expect(traces[0].draft.intent, 'unknown'); // OVERRIDE(expense->unknown)
      expect(traces[1].draft.intent, 'query'); // consulta ao histórico
      expect(traces[2].draft.intent, 'unknown'); // OVERRIDE(expense->unknown)
    });

    test('6. Ruído, pontuação isolada e 100% OOV acionam Zero-Vector Fallback', () {
      final traces = runGroup('OOV/Ruído', const [
        '?',
        '???',
        'xyzqwert asdfghj?',
        'blabla foo zzzq?',
      ]);
      for (final t in traces) {
        expect(t.intentModel.isZeroVectorFallback, isTrue);
        expect(t.intentModel.predictedLabel, 'unknown');
        expect(t.draft.intent, 'unknown');
        expect(t.vocabHitRate, 0.0);
      }
    });

    test('7. Benchmark de latência on-device (200 inferências parse + inspect)', () {
      const probes = [
        'gastei 50 no mercado no pix',
        'assinei a netflix de 55 no credito',
        'pix cai na hora?',
        'comprei um notebook de 4000 no credito em 10x',
        'recebi 4500 de salario',
        'qual o sentido da vida?',
      ];
      // Warmup
      for (final p in probes) {
        engine.parse(p);
        engine.inspect(p);
      }
      final swParse = Stopwatch()..start();
      const iters = 200;
      for (int i = 0; i < iters; i++) {
        engine.parse(probes[i % probes.length]);
      }
      swParse.stop();

      final inspectLatencies = <double>[];
      final swInspect = Stopwatch()..start();
      for (int i = 0; i < iters; i++) {
        final t = engine.inspect(probes[i % probes.length]);
        inspectLatencies.add(t.latencyMs);
      }
      swInspect.stop();
      inspectLatencies.sort();
      final p50 = inspectLatencies[inspectLatencies.length ~/ 2];
      final p95 = inspectLatencies[(inspectLatencies.length * 0.95).floor()];
      // ignore: avoid_print
      print(
        '\n[BENCHMARK ${iters}x] parse mean=${(swParse.elapsedMicroseconds / 1000 / iters).toStringAsFixed(3)} ms '
        '| inspect mean=${(swInspect.elapsedMicroseconds / 1000 / iters).toStringAsFixed(3)} ms '
        '| p50=${p50.toStringAsFixed(3)} ms | p95=${p95.toStringAsFixed(3)} ms',
      );
      expect(p95, lessThan(100.0));
    });

    test('8. Modelo esparso (Map) + Uncertainty Gate (Margem Δp e Entropia H) em produção', () {
      // Vocabulário sintético de 3 tokens neutros; "<token> R$ 50" => 3 tokens => tf = 1/3, idf = 3.0 => tfidf = 1.0
      final sparseModelJson = jsonEncode({
        'meta': {'confidence_threshold': 0.55},
        'vocabulary': {'alfa': 0, 'beta': 1, 'gama': 2},
        'idf': [3.0, 3.0, 3.0],
        'models': {
          'intent': {
            'classes': ['expense', 'income', 'query', 'transfer', 'unknown'],
            'intercept': [0.0, 0.0, -5.0, -5.0, -5.0],
            'coef': [
              // alfa: 0.28 -> Pmax~56.8%, Δp~13.9%; beta: 2.50 -> Pmax~92.3%
              {'0': 0.28, '1': 2.50},
              // gama: scores finais [0.0, -1.40, -1.45, -1.65, -2.05] => Pmax~55.5%, Δp~41.8%, H_norm~0.802
              {'2': -1.40},
              {'2': 3.55},
              {'2': 3.35},
              {'2': 2.95},
            ],
          },
          'category': {
            'classes': ['food', 'other'],
            'intercept': [0.0, -5.0],
            'coef': [
              {'1': 2.0},
              {},
            ],
          },
          'payment_method': {
            'classes': ['pix', 'cash'],
            'intercept': [0.0, -5.0],
            'coef': [
              {'1': 2.0},
              {},
            ],
          },
        },
      });

      final sparseEngine = LocalFinancialNlpEngine.fromJsonString(sparseModelJson);

      // Caso A: Margem Δp < 15% com Pmax < 72% (alfa R$ 50 -> Pmax~56.8%, Δp~13.9%) -> bloqueado para unknown
      final traceMargin = sparseEngine.inspect(r'alfa R$ 50');
      expect(traceMargin.intentModel.confidence, greaterThanOrEqualTo(0.55));
      expect(traceMargin.intentModel.margin, lessThan(0.15));
      expect(sparseEngine.parse(r'alfa R$ 50').intent, equals('unknown'));

      // Caso B: Alta entropia normalizada H_norm > 0.72 apesar de Pmax >= 0.55 e Δp >= 15% -> bloqueado para unknown
      final traceEntropy = sparseEngine.inspect(r'gama R$ 50');
      expect(traceEntropy.intentModel.confidence, greaterThanOrEqualTo(0.55));
      expect(traceEntropy.intentModel.margin, greaterThanOrEqualTo(0.15));
      expect(traceEntropy.intentModel.normalizedEntropy, greaterThan(0.72));
      expect(sparseEngine.parse(r'gama R$ 50').intent, equals('unknown'));

      // Caso C: Alta confiança e baixa entropia com pesos esparsos + cifra -> aprova expense
      final draftOk = sparseEngine.parse(r'beta R$ 50');
      expect(draftOk.intent, equals('expense'));
      expect(draftOk.amount, equals(50.0));
    });
  });
}
