import 'package:flutter_test/flutter_test.dart';
import 'package:krezio_ai/ai/voice/native_tts.dart';
import 'package:krezio_ai/ai/voice/voice_conversation_controller.dart';
import 'package:krezio_ai/ai/voice/voice_synthesis_service.dart';

class FakeNativeTts implements NativeTts {
  final spoken = <String>[];
  @override
  Future<void> speak(String text, {double rate = 1.0, double volume = 1.0}) async => spoken.add(text);
  @override
  Future<void> stop() async {}
}

void main() {
  group('6.2 voz nativa como alternativa', () {
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
  });
}
