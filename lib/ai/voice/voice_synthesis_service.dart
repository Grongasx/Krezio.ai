import 'dart:async';
import 'package:flutter/foundation.dart';
import 'audio_stream_player.dart';

/// Service responsible for Text-to-Speech (TTS) synthesis 100% via the On-Device ONNX Neural Model (Piper VITS).
/// Completely removes legacy Windows/browser speech synthesis engines.
class VoiceSynthesisService {
  static final VoiceSynthesisService _instance = VoiceSynthesisService._internal();
  factory VoiceSynthesisService() => _instance;

  VoiceSynthesisService._internal();
  VoiceSynthesisService.internal();

  bool _isInitialized = false;

  final ValueNotifier<bool> isSpeakingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String?> currentSpokenTextNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<String> activeVoiceNameNotifier = ValueNotifier<String>('Piper ONNX (pt_BR-faber-medium)');

  // Neural synthesis parameters
  final String modelName = 'pt_BR-faber-medium.onnx';
  final String architecture = 'Piper VITS (ONNX)';
  final int sampleRate = 22050;
  double _speechRate = 1.0; // Cadência neural (1.0x padrão calibrado)
  double _volume = 1.0;

  VoidCallback? onStart;
  VoidCallback? onCompletion;
  Function(dynamic)? onError;

  double get speechRate => _speechRate;
  double get volume => _volume;

  Future<void> initialize({String language = 'pt-BR'}) async {
    if (_isInitialized) return;
    _isInitialized = true;
    debugPrint('[VoiceSynthesisService] 🧠 César Voice Engine initialized: 100% ONNX ($modelName, $sampleRate Hz)');
  }

  /// Normalizes written text into fluent, natural conversational speech for the ONNX model.
  String preprocessTextForSpeech(String rawText) {
    var text = rawText;

    // Currency normalization: "R$ 150,00" -> "150 reais" / "R$ 150,50" -> "150 reais e 50 centavos"
    // Also handles thousands-grouped amounts: "R$ 1.948,40" -> "1948 reais e 40 centavos"
    // (the dotted group must be tried first, otherwise a lone \d+ eats only "1" and leaves
    // ".948,40" as unmatched, unspoken literal text trailing the sentence).
    text = text.replaceAllMapped(
      RegExp(r'R\$\s*(\d{1,3}(?:\.\d{3})+|\d+)(?:[.,](\d{1,2}))?'),
      (match) {
        final intPart = (match.group(1) ?? '0').replaceAll('.', '');
        final centPart = match.group(2);

        final realWord = intPart == '1' ? 'real' : 'reais';
        if (centPart == null || centPart == '00' || centPart == '0') {
          return '$intPart $realWord';
        }
        final cents = int.tryParse(centPart) ?? 0;
        final centWord = cents == 1 ? 'centavo' : 'centavos';
        return '$intPart $realWord e $cents $centWord';
      },
    );

    // Percentage normalization: "15%" -> "15 por cento"
    text = text.replaceAllMapped(
      RegExp(r'(\d+)%'),
      (match) => '${match.group(1)} por cento',
    );

    // Krezio.ai pronunciation
    text = text.replaceAll(RegExp(r'Krezio\.ai', caseSensitive: false), 'Krézio ai');

    // Add breathing micro-pauses for punctuation
    text = text.replaceAll(';', ',');
    text = text.replaceAll(' - ', ', ');

    return text.trim();
  }

  /// Speaks the provided text using EXCLUSIVELY the On-Device ONNX model.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;

    if (!_isInitialized) {
      await initialize();
    }

    final speechReadyText = preprocessTextForSpeech(text);

    try {
      final encoded = Uri.encodeComponent(speechReadyText);
      final onnxUrl = 'http://127.0.0.1:8088/synthesize?text=$encoded';

      currentSpokenTextNotifier.value = speechReadyText;
      isSpeakingNotifier.value = true;
      onStart?.call();

      final played = await AudioStreamPlayer.playUrl(
        onnxUrl,
        onCompletion: () {
          isSpeakingNotifier.value = false;
          currentSpokenTextNotifier.value = null;
          onCompletion?.call();
        },
        onError: (e) {
          debugPrint('[VoiceSynthesisService] ONNX audio stream error: $e');
          isSpeakingNotifier.value = false;
          currentSpokenTextNotifier.value = null;
          onError?.call(e);
          onCompletion?.call();
        },
      );

      if (!played) {
        debugPrint('[VoiceSynthesisService] Could not play ONNX audio stream.');
        isSpeakingNotifier.value = false;
        currentSpokenTextNotifier.value = null;
        onCompletion?.call();
      }
    } catch (e) {
      debugPrint('[VoiceSynthesisService] ONNX Speak error: $e');
      isSpeakingNotifier.value = false;
      currentSpokenTextNotifier.value = null;
      onError?.call(e);
      onCompletion?.call();
    }
  }

  /// Adjusts speech rate (0.5 to 1.5).
  Future<void> setSpeechRate(double newRate) async {
    _speechRate = newRate.clamp(0.5, 1.5);
  }

  /// Adjusts volume (0.0 to 1.0).
  Future<void> setVolume(double newVolume) async {
    _volume = newVolume.clamp(0.0, 1.0);
  }

  /// Stops current speech immediately.
  Future<void> stop() async {
    try {
      AudioStreamPlayer.stop();
      isSpeakingNotifier.value = false;
      currentSpokenTextNotifier.value = null;
    } catch (e) {
      debugPrint('[VoiceSynthesisService] Stop error: $e');
    }
  }

  void dispose() {
    stop();
    isSpeakingNotifier.dispose();
    currentSpokenTextNotifier.dispose();
    activeVoiceNameNotifier.dispose();
  }
}
