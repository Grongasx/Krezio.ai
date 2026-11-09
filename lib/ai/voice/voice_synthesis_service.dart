import 'dart:async';
import 'package:flutter/foundation.dart';
import 'audio_stream_player.dart';
import 'native_tts.dart';

enum VoiceAvailability { checking, systemVoice, piper, unavailable }

enum _PiperOutcome { completed, failed, interrupted }

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
  final ValueNotifier<VoiceAvailability> availabilityNotifier =
      ValueNotifier<VoiceAvailability>(VoiceAvailability.checking);

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
  }

  /// Normalizes written text into fluent, natural conversational speech for the ONNX model.
  String preprocessTextForSpeech(String rawText) {
    var text = rawText;

    // Currency normalization: "R$ 150,00" -> "150 reais" / "R$ 150,50" -> "150 reais e 50 centavos"
    // Also handles thousands-grouped amounts: "R$ 1.948,40" -> "1948 reais e 40 centavos"
    // (the dotted group must be tried first, otherwise a lone \d+ eats only "1" and leaves
    // ".948,40" as unmatched, unspoken literal text trailing the sentence).
    text = text.replaceAllMapped(
      RegExp(r'(-\s*)?R\$\s*(\d{1,3}(?:\.\d{3})+|\d+)(?:[.,](\d{1,2}))?'),
      (match) {
        final sign = match.group(1) == null ? '' : 'menos ';
        final intPart = match.group(2)!.replaceAll('.', '');
        final centPart = match.group(3);

        final realWord = intPart == '1' ? 'real' : 'reais';
        if (centPart == null || centPart == '00' || centPart == '0') {
          return '$sign$intPart $realWord';
        }
        final cents = int.tryParse(centPart) ?? 0;
        final centWord = cents == 1 ? 'centavo' : 'centavos';
        return '$sign$intPart $realWord e $cents $centWord';
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
  Completer<_PiperOutcome>? _piperEnded;
  bool _usingNative = false;
  Future<void>? _stoppingNative;

  /// Uses the system voice on phones and when Piper cannot start elsewhere.
  Future<void> speak(String text) async {
    final speechReadyText = preprocessTextForSpeech(text);
    if (speechReadyText.isEmpty) return;

    final id = ++_speechId;
    await _cancelPlayback();
    if (!_isInitialized) {
      await initialize();
    }
    if (id != _speechId) return;

    availabilityNotifier.value = VoiceAvailability.checking;
    currentSpokenTextNotifier.value = speechReadyText;
    isSpeakingNotifier.value = true;
    onStart?.call();

    try {
      if (id != _speechId) return;
      if (!preferNative && await _tryPiper(speechReadyText, id)) return;
      if (id != _speechId) return;

      _usingNative = true;
      await nativeTts.speak(speechReadyText, rate: _speechRate, volume: _volume);
      if (id == _speechId) {
        availabilityNotifier.value = VoiceAvailability.systemVoice;
      }
    } catch (error) {
      if (id == _speechId) {
        availabilityNotifier.value = VoiceAvailability.unavailable;
        onError?.call(error);
      }
    } finally {
      if (id == _speechId) {
        _usingNative = false;
        _piperEnded = null;
        isSpeakingNotifier.value = false;
        currentSpokenTextNotifier.value = null;
        onCompletion?.call();
      }
    }
  }

  Future<bool> _tryPiper(String text, int id) async {
    final ended = Completer<_PiperOutcome>();
    _piperEnded = ended;
    var failedBeforeStart = false;
    var started = false;
    void finish(_PiperOutcome outcome) {
      if (!ended.isCompleted) ended.complete(outcome);
    }

    try {
      final onnxUrl = 'http://127.0.0.1:8088/synthesize?text=${Uri.encodeComponent(text)}';
      started = await onnxPlayer(
        onnxUrl,
        onCompletion: () => finish(_PiperOutcome.completed),
        onError: (_) {
          failedBeforeStart = !started;
          finish(_PiperOutcome.failed);
        },
      ).timeout(onnxTimeout, onTimeout: () => false);
    } catch (_) {
      started = false;
    }

    if (id != _speechId) return false;
    if (!started || failedBeforeStart) {
      AudioStreamPlayer.stop();
      finish(_PiperOutcome.interrupted);
      return false;
    }

    availabilityNotifier.value = VoiceAvailability.piper;
    if (await ended.future == _PiperOutcome.failed && id == _speechId) {
      // Audio already started. Keep the text available without replaying an
      // utterance the user may already have heard in part.
      AudioStreamPlayer.stop();
      throw StateError('A reprodução da voz Piper foi interrompida.');
    }
    return true;
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
    isSpeakingNotifier.value = false;
    currentSpokenTextNotifier.value = null;
    await _cancelPlayback();
  }

  Future<void> _cancelPlayback() async {
    final ended = _piperEnded;
    _piperEnded = null;
    AudioStreamPlayer.stop();
    if (ended != null && !ended.isCompleted) {
      ended.complete(_PiperOutcome.interrupted);
    }
    if (_usingNative) {
      _usingNative = false;
      _stoppingNative = _stopNative();
    }
    final stopping = _stoppingNative;
    if (stopping == null) return;
    await stopping;
    if (identical(_stoppingNative, stopping)) _stoppingNative = null;
  }

  Future<void> _stopNative() async {
    try {
      await _native?.stop();
    } catch (e) {
      debugPrint('[VoiceSynthesisService] Stop error: $e');
    }
  }

  void dispose() {
    stop();
    isSpeakingNotifier.dispose();
    currentSpokenTextNotifier.dispose();
    availabilityNotifier.dispose();
  }
}
