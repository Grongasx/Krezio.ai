import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'audio_stream_player.dart';
import 'native_tts.dart';
import 'voice_onnx_manager.dart';

enum VoiceAvailability { checking, systemVoice, piper, unavailable }

enum _PiperOutcome { completed, failed, interrupted }

/// César's voice: defaults to Google's male voice (`com.google.android.tts` /
/// `pt-br-x-ptd-local`), and supports the lightweight INT8 quantized Piper VITS
/// ONNX model (`pt_BR-faber-int8.onnx`) on-device when enabled.
class VoiceSynthesisService {
  static final VoiceSynthesisService _instance = VoiceSynthesisService._internal();
  factory VoiceSynthesisService() => _instance;

  VoiceSynthesisService._internal();
  VoiceSynthesisService.internal();

  static const String prefSpeechRate = 'krezio_voice_speech_rate';
  static const List<double> speedPresets = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

  static String speedLabelOf(double rate) {
    if (rate < 0.9) return 'Calma';
    if (rate < 1.15) return 'Normal';
    if (rate < 1.4) return 'Ágil';
    if (rate < 1.65) return 'Rápida';
    return 'Turbo';
  }

  bool _isInitialized = false;

  final ValueNotifier<bool> isSpeakingNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<String?> currentSpokenTextNotifier = ValueNotifier<String?>(null);
  final ValueNotifier<VoiceAvailability> availabilityNotifier =
      ValueNotifier<VoiceAvailability>(VoiceAvailability.checking);
  final ValueNotifier<double> speechRateNotifier = ValueNotifier<double>(1.0);

  // Neural synthesis parameters (Option 3: Lightweight Quantized INT8 + Google Male Default)
  final VoiceOnnxManager onnxManager = VoiceOnnxManager();
  final String modelName = 'pt_BR-faber-medium.onnx';
  final String quantizedModelName = 'pt_BR-faber-int8.onnx';
  final String quantization = 'int8';
  final String defaultEngine = FlutterNativeTts.googleEngine;
  final String defaultVoice = FlutterNativeTts.defaultGoogleMaleVoice;
  final String architecture = 'Piper VITS (ONNX)';
  final int sampleRate = 22050;
  double _speechRate = 1.0; // Cadência neural (1.0x padrão calibrado ágil)
  double _volume = 1.0;

  VoidCallback? onStart;
  VoidCallback? onCompletion;
  Function(dynamic)? onError;

  double get speechRate => _speechRate;
  double get volume => _volume;

  Future<void> initialize({String language = 'pt-BR'}) async {
    if (_isInitialized) return;
    _isInitialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedRate = prefs.getDouble(prefSpeechRate);
      if (savedRate != null) {
        _speechRate = savedRate.clamp(0.5, 2.0);
        speechRateNotifier.value = _speechRate;
      }
    } catch (_) {}
    await onnxManager.initialize();
  }

  /// Switches between the default Google Male system voice and the quantized INT8 Piper ONNX model.
  void setUseQuantizedOnnx(bool enabled) {
    preferNative = !enabled;
    onnxManager.toggleUseOnnx(enabled);
  }

  /// Normalizes written text into fluent, natural conversational speech for the ONNX / TTS engine.
  String preprocessTextForSpeech(String rawText) {
    var text = rawText;

    // Strip markdown headings and list bullets at line starts so multi-line messages read cleanly
    text = text.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
    text = text.replaceAll(RegExp(r'^\s*[-*•]\s+', multiLine: true), '');

    // Strip markdown formatting and bullet symbols so TTS doesn't read them literally
    text = text.replaceAll(RegExp(r'[*_`•]'), '');
    text = text.replaceAll(' · ', ', ');
    text = text.replaceAll(
      RegExp(r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]', unicode: true),
      '',
    );

    // Convert line breaks into natural sentence pauses so TTS reads all lines without stopping at \n
    text = text.replaceAllMapped(
      RegExp(r'([^\s.!?:;,])\s*\r?\n+\s*'),
      (m) => '${m.group(1)}. ',
    );
    text = text.replaceAll(RegExp(r'\r?\n+'), ' ');

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

    // Installments normalization: "10x" -> "10 vezes", "1x" -> "1 vez"
    text = text.replaceAllMapped(
      RegExp(r'\b(\d+)\s*[xX]\b'),
      (match) {
        final count = match.group(1)!;
        return count == '1' ? '1 vez' : '$count vezes';
      },
    );

    // Ordinal days: "5º" -> "quinto", "1º" -> "primeiro"
    const ordinals = {
      '1': 'primeiro',
      '2': 'segundo',
      '3': 'terceiro',
      '4': 'quarto',
      '5': 'quinto',
      '6': 'sexto',
      '7': 'sétimo',
      '8': 'oitavo',
      '9': 'nono',
      '10': 'décimo',
    };
    text = text.replaceAllMapped(
      RegExp(r'\b(\d{1,2})º(?=\s|[.,!?;:]|$)'),
      (m) => ordinals[m.group(1)] ?? '${m.group(1)}º',
    );

    // Percentage normalization: "15%" -> "15 por cento"
    text = text.replaceAllMapped(
      RegExp(r'(\d+)%'),
      (match) => '${match.group(1)} por cento',
    );

    // Krezio.ai pronunciation
    text = text.replaceAll(RegExp(r'Krezio\.ai', caseSensitive: false), 'Krézio ai');

    // Word slashes: "débito/crédito" -> "débito ou crédito"
    text = text.replaceAllMapped(
      RegExp(r'([A-Za-zÀ-ÿ]+)/([A-Za-zÀ-ÿ]+)'),
      (m) => '${m.group(1)} ou ${m.group(2)}',
    );

    // Add breathing micro-pauses for punctuation
    text = text.replaceAll(';', ',');
    text = text.replaceAll(' - ', ', ');
    text = text.replaceAll(' — ', ', ');
    text = text.replaceAll(RegExp(r'\s{2,}'), ' ');

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
      final onnxUrl = onnxManager.buildSynthesisUrl(text, speechRate: _speechRate);
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

  /// Adjusts speech rate (0.5 to 2.0) and persists it across sessions.
  Future<void> setSpeechRate(double newRate) async {
    _speechRate = newRate.clamp(0.5, 2.0);
    speechRateNotifier.value = _speechRate;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(prefSpeechRate, _speechRate);
    } catch (_) {}
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
    if (_usingNative || _native != null) {
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
    speechRateNotifier.dispose();
  }
}
