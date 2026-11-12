import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/voice/native_tts.dart';
import 'package:krezio_ai/ai/voice/voice_conversation_controller.dart';
import 'package:krezio_ai/ai/voice/voice_synthesis_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeNativeTts implements NativeTts {
  final spoken = <String>[];
  @override
  Future<void> speak(String text, {double rate = 1.0, double volume = 1.0}) async => spoken.add(text);
  @override
  Future<void> stop() async {}
}

class UnavailableNativeTts extends FakeNativeTts {
  @override
  Future<void> speak(String text, {double rate = 1.0, double volume = 1.0}) async {
    throw StateError('voz indisponível');
  }
}

void main() {
  group('6.2 voz nativa como alternativa', () {
    test('falha das duas vozes encerra a tentativa uma vez', () async {
      var errors = 0;
      var completions = 0;
      final service = VoiceSynthesisService.internal()
        ..preferNative = false
        ..nativeTts = UnavailableNativeTts()
        ..onnxPlayer = (url, {onCompletion, onError}) async {
          return false;
        }
        ..onError = (_) {
          errors++;
        }
        ..onCompletion = () {
          completions++;
        };
      await service.speak('Oi');
      expect(service.availabilityNotifier.value, VoiceAvailability.unavailable);
      expect(service.isSpeakingNotifier.value, isFalse);
      expect(errors, 1);
      expect(completions, 1);
    });

    test('servidor ONNX não responde em 1 s: fala com a voz do sistema', () async {
      final native = FakeNativeTts();
      var completed = 0;
      final s = VoiceSynthesisService.internal()
        ..preferNative = false
        ..nativeTts = native
        ..onnxTimeout = const Duration(milliseconds: 50)
        ..onnxPlayer = ((url, {onCompletion, onError}) => Future.delayed(const Duration(seconds: 5), () => true))
        ..onCompletion = () => completed++;
      await s.speak('Gastei R\$ 50,00 no mercado');
      expect(native.spoken.single, 'Gastei 50 reais no mercado');
      expect(s.availabilityNotifier.value, VoiceAvailability.systemVoice);
      expect(completed, 1);
      expect(s.isSpeakingNotifier.value, isFalse);
    });

    test('servidor recusou (play falhou): voz do sistema', () async {
      final native = FakeNativeTts();
      final s = VoiceSynthesisService.internal()
        ..preferNative = false
        ..nativeTts = native
        ..onnxPlayer = (url, {onCompletion, onError}) async => false;
      await s.speak('Oi');
      expect(native.spoken, ['Oi']);
    });

    test('servidor responde: usa a voz neural, não a do sistema', () async {
      final native = FakeNativeTts();
      final s = VoiceSynthesisService.internal()
        ..preferNative = false
        ..nativeTts = native
        ..onnxPlayer = (url, {onCompletion, onError}) async {
          onCompletion?.call();
          return true;
        };
      await s.speak('Oi');
      expect(native.spoken, isEmpty);
      expect(s.availabilityNotifier.value, VoiceAvailability.piper);
    });

    test('no celular a voz do sistema é o padrão', () async {
      final native = FakeNativeTts();
      var onnxCalled = false;
      final s = VoiceSynthesisService.internal()
        ..preferNative = true
        ..nativeTts = native
        ..onnxPlayer = (url, {onCompletion, onError}) async => onnxCalled = true;
      await s.speak('Oi');
      expect(onnxCalled, isFalse);
      expect(native.spoken, ['Oi']);
    });
  });

  group('6.3 mãos-livres', () {
    test('"tchau César" encerra; frases normais não', () {
      for (final s in ['tchau', 'Tchau, César!', 'até mais', 'obrigado, tchau', 'pode parar', 'valeu tchau cesar']) {
        expect(VoiceConversationController.isGoodbye(s), isTrue, reason: s);
      }
      for (final s in ['gastei 50 no mercado', 'tchau tchau pro dinheiro gastei 30', 'quanto gastei até mais ou menos ontem']) {
        expect(VoiceConversationController.isGoodbye(s), isFalse, reason: s);
      }
    });
  });

  group('voz masculina no celular', () {
    // Vozes como o Android do Redmi (Google TTS) e o Windows as listam.
    final android = [
      {'name': 'pt-br-x-afs-local', 'locale': 'pt-BR', 'network_required': '0', 'features': ''},
      {'name': 'pt-br-x-pte-network', 'locale': 'pt-BR', 'network_required': '1', 'features': ''},
      {'name': 'pt-br-x-ptd-network', 'locale': 'pt-BR', 'network_required': '1', 'features': ''},
      {'name': 'pt-br-x-ptd-local', 'locale': 'pt-BR', 'network_required': '0', 'features': ''},
      {'name': 'pt-pt-x-jmn-local', 'locale': 'pt-PT', 'network_required': '0', 'features': ''},
      {'name': 'en-us-x-iol-local', 'locale': 'en-US', 'network_required': '0', 'features': ''},
      {'name': 'pt-br-x-ptc-local', 'locale': 'pt-BR', 'network_required': '0', 'features': 'notInstalled'},
    ];

    test('escolhe uma voz masculina brasileira, local de preferência', () {
      final voices = VoicePicker.portuguese(android);
      expect(voices.any((v) => v.locale.startsWith('en')), isFalse);
      expect(voices.any((v) => v.name.contains('ptc')), isFalse, reason: 'voz não instalada fica de fora');
      expect(VoicePicker.choose(voices)!.name, 'pt-br-x-ptd-local');
      expect(voices.where((v) => v.male).map((v) => v.name), isNot(contains('pt-br-x-afs-local')));
    });

    test('a escolha do usuário vale mais que a automática', () {
      final voices = VoicePicker.portuguese(android);
      expect(VoicePicker.choose(voices, chosen: 'pt-br-x-afs-local')!.name, 'pt-br-x-afs-local');
      expect(VoicePicker.choose(voices, chosen: 'nao-existe')!.name, 'pt-br-x-ptd-local');
    });

    test('Windows e iOS dizem o gênero', () {
      final voices = VoicePicker.portuguese([
        {'name': 'Microsoft Maria - Portuguese (Brazil)', 'locale': 'pt-BR', 'gender': 'female'},
        {'name': 'Microsoft Daniel - Portuguese (Brazil)', 'locale': 'pt-BR', 'gender': 'male'},
      ]);
      expect(VoicePicker.choose(voices)!.name, contains('Daniel'));
    });

    test('sem voz masculina: nenhuma escolhida (o tom fica mais grave)', () {
      expect(VoicePicker.choose(VoicePicker.portuguese([
        {'name': 'pt-br-x-afs-local', 'locale': 'pt-BR'},
      ])), isNull);
      expect(FlutterNativeTts.fallbackPitch, lessThan(1));
    });

    test('prioriza a voz masculina padrão do Google sobre outras vozes masculinas', () {
      final voices = VoicePicker.portuguese([
        {'name': 'Microsoft Daniel - Portuguese (Brazil)', 'locale': 'pt-BR', 'gender': 'male'},
        {'name': 'pt-br-x-ptd-local', 'locale': 'pt-BR', 'network_required': '0', 'features': ''},
      ]);
      final chosen = VoicePicker.choose(voices)!;
      expect(chosen.name, 'pt-br-x-ptd-local');
      expect(chosen.male, isTrue);
      expect(chosen.isGoogle, isTrue);
      expect(FlutterNativeTts.googleEngine, 'com.google.android.tts');
      expect(FlutterNativeTts.defaultGoogleMaleVoice, 'pt-br-x-ptd-local');
    });

    test('Opção 3: Piper VITS INT8 quantizado e cache local com padrão Google masculino', () async {
      final s = VoiceSynthesisService.internal();
      await s.initialize();
      expect(s.quantizedModelName, 'pt_BR-faber-int8.onnx');
      expect(s.quantization, 'int8');
      expect(s.defaultEngine, 'com.google.android.tts');
      expect(s.defaultVoice, 'pt-br-x-ptd-local');
      expect(s.onnxManager.gender, 'male');

      final url1 = s.onnxManager.buildSynthesisUrl('Olá! Eu sou o César.');
      final url2 = s.onnxManager.buildSynthesisUrl('Olá! Eu sou o César.');
      expect(url1, contains('pt_BR-faber-int8.onnx'));
      expect(url1, contains('quantization=int8'));
      expect(url1, contains('gender=male'));
      expect(url1, equals(url2));
      expect(s.onnxManager.cachedPhraseCount, greaterThanOrEqualTo(1));
    });

    test('velocidade de comunicação calibrada e ajustável até 2.0x', () async {
      final s = VoiceSynthesisService.internal();
      expect(FlutterNativeTts.calibratedBaseRate, greaterThan(0.5));
      expect(FlutterNativeTts.platformRateFor(1.0, isWeb: false), closeTo(0.65, 0.001));
      expect(FlutterNativeTts.platformRateFor(1.5, isWeb: false), closeTo(0.975, 0.001));
      expect(FlutterNativeTts.platformRateFor(1.0, isWeb: true), closeTo(1.15, 0.001));

      await s.setSpeechRate(1.5);
      expect(s.speechRate, 1.5);
      expect(s.speechRateNotifier.value, 1.5);
      expect(VoiceSynthesisService.speedLabelOf(1.5), 'Rápida');
      expect(VoiceSynthesisService.speedLabelOf(1.75), 'Turbo');
    });

    test('prioriza vozes masculinas neurais/HD e humaniza cláusulas e texto falado', () {
      final voices = VoicePicker.portuguese(android);
      final naturalChoice = VoicePicker.choose(voices, preferNatural: true)!;
      expect(naturalChoice.name, 'pt-br-x-ptd-network');
      expect(naturalChoice.isNatural, isTrue);

      final clauses = VoicePicker.splitIntoNaturalClauses('Pronto! Anotei 50 reais. Quer lançar mais alguma coisa?');
      expect(clauses, ['Pronto!', 'Anotei 50 reais.', 'Quer lançar mais alguma coisa?']);

      final s = VoiceSynthesisService.internal();
      expect(
        s.preprocessTextForSpeech('**Parcelado** em 10x no 5º dia útil no débito/crédito 🎉'),
        'Parcelado em 10 vezes no quinto dia útil no débito ou crédito',
      );
      expect(
        s.preprocessTextForSpeech('### Resumo\n- Mercado: R\$ 50,00\n- Uber: R\$ 30,00'),
        'Resumo. Mercado: 50 reais. Uber: 30 reais',
      );
    });
  });

  group('FlutterNativeTts sem duplicação de voz', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Web (retorno null de awaitSpeakCompletion): fala 1x na voz certa sem cair no fallback', () async {
      final backend = _FakeTtsBackend(
        availableVoices: [
          {'name': 'Microsoft Antonio Online (Natural) - Portuguese (Brazil)', 'locale': 'pt-BR', 'network_required': '1'},
          {'name': 'pt-br-x-ptd-local', 'locale': 'pt-BR', 'network_required': '0'},
        ],
        onSpeak: (b, text) async {
          b.spokenLog.add((voice: b.activeVoice, text: text));
          b.completionHandler?.call();
          return null; // flutter_tts_web completa Completer() sem valor (null)
        },
      );
      final tts = FlutterNativeTts(
        backend: backend,
        isWebOverride: true,
        platformOverride: TargetPlatform.windows,
      );

      await tts.speak('Pronto! Anotei 50 reais.');

      expect(backend.spokenLog.length, 2);
      expect(backend.spokenLog.map((e) => e.text).toList(), ['Pronto!', 'Anotei 50 reais.']);
      expect(
        backend.spokenLog.every((e) => e.voice == 'Microsoft Antonio Online (Natural) - Portuguese (Brazil)'),
        isTrue,
      );
    });

    test('Android (retorno 1 + completionHandler): fala 1x sem fallback', () async {
      final backend = _FakeTtsBackend(
        availableVoices: [
          {'name': 'pt-br-x-ptd-local', 'locale': 'pt-BR', 'network_required': '0'},
          {'name': 'pt-br-x-ptd-network', 'locale': 'pt-BR', 'network_required': '1'},
        ],
        onSpeak: (b, text) async {
          b.spokenLog.add((voice: b.activeVoice, text: text));
          b.completionHandler?.call();
          return 1;
        },
      );
      final tts = FlutterNativeTts(
        backend: backend,
        isWebOverride: false,
        platformOverride: TargetPlatform.android,
      );

      await tts.speak('Saldo de 200 reais.');

      expect(backend.spokenLog.length, 1);
      expect(backend.spokenLog.single.voice, 'pt-br-x-ptd-local');
    });

    test('rejeição antes de falar (retorno 0): faz fallback para voz local uma única vez', () async {
      final backend = _FakeTtsBackend(
        availableVoices: [
          {'name': 'Microsoft Antonio Online (Natural) - Portuguese (Brazil)', 'locale': 'pt-BR', 'network_required': '1'},
          {'name': 'pt-br-x-ptd-local', 'locale': 'pt-BR', 'network_required': '0'},
        ],
        onSpeak: (b, text) async {
          b.spokenLog.add((voice: b.activeVoice, text: text));
          if (b.activeVoice!.contains('Antonio')) {
            return 0; // falhou antes de tocar na voz online
          }
          b.completionHandler?.call();
          return 1;
        },
      );
      final tts = FlutterNativeTts(
        backend: backend,
        isWebOverride: true,
        platformOverride: TargetPlatform.windows,
      );

      await tts.speak('Teste de fallback.');

      expect(backend.spokenLog.length, 2);
      expect(backend.spokenLog[0].voice, contains('Antonio'));
      expect(backend.spokenLog[1].voice, 'pt-br-x-ptd-local');
    });

    test('erro no Web após já ter falado >= 400ms não repete a mensagem em outra voz', () async {
      final neverCompletesSpeak = Completer<dynamic>();
      final backend = _FakeTtsBackend(
        availableVoices: [
          {'name': 'Microsoft Antonio Online (Natural) - Portuguese (Brazil)', 'locale': 'pt-BR', 'network_required': '1'},
          {'name': 'pt-br-x-ptd-local', 'locale': 'pt-BR', 'network_required': '0'},
        ],
        onSpeak: (b, text) async {
          b.spokenLog.add((voice: b.activeVoice, text: text));
          if (b.activeVoice!.contains('Antonio')) {
            await Future.delayed(const Duration(milliseconds: 450));
            b.errorHandler?.call('network-error');
            return neverCompletesSpeak.future;
          }
          b.completionHandler?.call();
          return null;
        },
      );
      final tts = FlutterNativeTts(
        backend: backend,
        isWebOverride: true,
        platformOverride: TargetPlatform.windows,
      );

      await expectLater(tts.speak('Não repete.'), throwsStateError);
      expect(backend.spokenLog.length, 1);
      expect(backend.spokenLog.single.voice, contains('Antonio'));
    });
  });
}

class _FakeTtsBackend implements TtsBackend {
  final List<Map<String, String>> availableVoices;
  final Future<dynamic> Function(_FakeTtsBackend backend, String text) onSpeak;
  final spokenLog = <({String? voice, String text})>[];
  String? activeVoice;
  VoidCallback? completionHandler;
  void Function(dynamic)? errorHandler;

  _FakeTtsBackend({required this.availableVoices, required this.onSpeak});

  @override
  Future<void> awaitSpeakCompletion(bool value) async {}

  @override
  Future<List<String>> getEngines() async => const ['com.google.android.tts'];

  @override
  Future<List<Map<String, String>>> getVoices() async => availableVoices;

  @override
  void setCompletionHandler(VoidCallback handler) => completionHandler = handler;

  @override
  Future<void> setEngine(String engine) async {}

  @override
  void setErrorHandler(void Function(dynamic message) handler) => errorHandler = handler;

  @override
  Future<void> setLanguage(String language) async {}

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> setSpeechRate(double rate) async {}

  @override
  Future<void> setVoice(Map<String, String> voice) async => activeVoice = voice['name'];

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<dynamic> speak(String text) => onSpeak(this, text);

  @override
  Future<void> stop() async {}
}
