import 'dart:async';
import 'package:flutter/foundation.dart';
import 'audio_stream_player.dart';
import 'native_tts.dart';

/// César's voice: the neural ONNX model (Piper VITS) when its server answers,
/// the system voice otherwise (and by default on phones).
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

  /// The system voice, used when the neural voice server doesn't answer.
  NativeTts? _native;
  NativeTts get nativeTts => _native ??= FlutterNativeTts();
  set nativeTts(NativeTts tts) => _native = tts;

  /// Plays a neural voice stream; swappable in tests.
  Future<bool> Function(String url, {void Function()? onCompletion, void Function(dynamic)? onError}) onnxPlayer =
      AudioStreamPlayer.playUrl;

  /// How long the neural voice has to start before César falls back to the
  /// system voice.
  Duration onnxTimeout = const Duration(seconds: 1);

  /// On a phone the neural server (on the PC) isn't reachable: the system
  /// voice is the default there. Settable by the user.
  bool preferNative = !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  int _speechId = 0;

  /// Speaks [text] with the neural ONNX voice (Piper, served on the PC) or,
  /// when it doesn't start within [onnxTimeout] — or on a phone — with the
  /// system voice. César always speaks.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;

    if (!_isInitialized) {
      await initialize();
    }

    final speechReadyText = preprocessTextForSpeech(text);
    final id = ++_speechId;
    currentSpokenTextNotifier.value = speechReadyText;
    isSpeakingNotifier.value = true;
    onStart?.call();

    if (preferNative) {
      await _speakNative(speechReadyText, id);
      return;
    }

    var finished = false;
    void finish() {
      if (finished || id != _speechId) return;
      finished = true;
      isSpeakingNotifier.value = false;
      currentSpokenTextNotifier.value = null;
      onCompletion?.call();
    }

    bool played;
    try {
      final onnxUrl = 'http://127.0.0.1:8088/synthesize?text=${Uri.encodeComponent(speechReadyText)}';
      played = await onnxPlayer(
        onnxUrl,
        onCompletion: finish,
        onError: (e) {
          debugPrint('[VoiceSynthesisService] ONNX audio stream error: $e');
          finish();
        },
      ).timeout(onnxTimeout, onTimeout: () => false);
    } catch (e) {
      debugPrint('[VoiceSynthesisService] ONNX speak error: $e');
      played = false;
    }
    if (played || id != _speechId) return;

    // No neural voice: the system voice says it.
    finished = true;
    AudioStreamPlayer.stop();
    await _speakNative(speechReadyText, id);
  }

  Future<void> _speakNative(String text, int id) async {
    activeVoiceNameNotifier.value = 'Voz do sistema';
    try {
      await nativeTts.speak(text, rate: _speechRate, volume: _volume);
    } catch (e) {
      debugPrint('[VoiceSynthesisService] native voice error: $e');
      onError?.call(e);
    }
    if (id != _speechId) return; // stopped or replaced meanwhile
    isSpeakingNotifier.value = false;
    currentSpokenTextNotifier.value = null;
    onCompletion?.call();
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
    _speechId++;
    try {
      AudioStreamPlayer.stop();
      await _native?.stop();
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
