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
}
