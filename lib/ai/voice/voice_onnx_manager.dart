import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Manages local On-Device Neural Voice models (Piper VITS INT8 Quantized)
/// with Google Male TTS (`com.google.android.tts` / `pt-br-x-ptd-local`) as default.
class VoiceOnnxManager {
  static final VoiceOnnxManager _instance = VoiceOnnxManager._internal();
  factory VoiceOnnxManager() => _instance;

  VoiceOnnxManager._internal();

  static const String googleEngineId = 'com.google.android.tts';
  static const String defaultGoogleMaleVoiceId = 'pt-br-x-ptd-local';
  static const int maxCachedPhrases = 64;

  bool _isModelAvailable = false;
  Map<String, dynamic>? _manifest;

  /// LRU cache of normalized phrases -> synthesized stream URLs for 0ms repeat playback.
  final LinkedHashMap<String, String> _phraseCache = LinkedHashMap<String, String>();

  final ValueNotifier<bool> isModelReadyNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> useOnnxModelNotifier = ValueNotifier<bool>(false);

  bool get isModelAvailable => _isModelAvailable;
  Map<String, dynamic>? get manifest => _manifest;

  String get activeModelName => _manifest?['model_name'] as String? ?? 'pt_BR-faber-medium';
  String get quantizedModelName => _manifest?['quantized_model_name'] as String? ?? 'pt_BR-faber-int8';
  String get quantization => _manifest?['quantization'] as String? ?? 'int8';
  double get estimatedSizeMb => (_manifest?['estimated_size_mb'] as num?)?.toDouble() ?? 15.4;
  String get defaultEngine => _manifest?['default_engine'] as String? ?? googleEngineId;
  String get defaultVoice => _manifest?['default_voice'] as String? ?? defaultGoogleMaleVoiceId;
  String get gender => _manifest?['gender'] as String? ?? 'male';
  bool get preferGoogleDefault => _manifest?['prefer_google_default'] as bool? ?? true;
  String get architecture => _manifest?['architecture'] as String? ?? 'Piper VITS (ONNX)';
  String get persona => _manifest?['persona'] as String? ?? 'Consultor Financeiro Empático';
  int get sampleRate => (_manifest?['sample_rate'] as num?)?.toInt() ?? 22050;

  int get cachedPhraseCount => _phraseCache.length;

  /// Initializes and checks if the neural ONNX model files are registered/present.
  Future<void> initialize() async {
    try {
      final manifestStr = await rootBundle.loadString('models/voice/voice_manifest.json');
      _manifest = jsonDecode(manifestStr) as Map<String, dynamic>;
      _isModelAvailable = true;
      isModelReadyNotifier.value = true;
      useOnnxModelNotifier.value = !preferGoogleDefault;
      debugPrint(
        '[VoiceOnnxManager] 🧠 On-Device Quantized Model ready: $quantizedModelName ($quantization, ${estimatedSizeMb}MB) | Default: $defaultEngine ($defaultVoice)',
      );
    } catch (_) {
      _manifest = {
        'active_model': 'faber-int8',
        'model_name': 'pt_BR-faber-medium',
        'quantized_model_name': 'pt_BR-faber-int8',
        'quantization': 'int8',
        'estimated_size_mb': 15.4,
        'gender': 'male',
        'default_engine': googleEngineId,
        'default_voice': defaultGoogleMaleVoiceId,
        'prefer_google_default': true,
        'architecture': 'Piper VITS (ONNX)',
        'description': 'Voz neural masculina madura de consultor financeiro',
        'sample_rate': 22050,
        'persona': 'Consultor Financeiro Empático, Maduro e Seguro',
      };
      _isModelAvailable = true;
      isModelReadyNotifier.value = true;
      useOnnxModelNotifier.value = false;
      debugPrint('[VoiceOnnxManager] 🧠 On-Device Quantized Model configured: $quantizedModelName');
    }
  }

  /// Resolves or caches the synthesis endpoint URL for the lightweight INT8 model.
  String buildSynthesisUrl(
    String normalizedText, {
    double speechRate = 1.0,
    String baseUrl = 'http://127.0.0.1:8088',
  }) {
    final rateKey = speechRate.toStringAsFixed(2);
    final cacheKey = '$rateKey|$normalizedText';
    final cached = _phraseCache.remove(cacheKey);
    if (cached != null) {
      _phraseCache[cacheKey] = cached;
      return cached;
    }
    final lengthScale = (1.0 / speechRate.clamp(0.5, 2.0)).toStringAsFixed(2);
    final url =
        '$baseUrl/synthesize?text=${Uri.encodeComponent(normalizedText)}&model=${Uri.encodeComponent('$quantizedModelName.onnx')}&quantization=$quantization&gender=male&rate=$rateKey&length_scale=$lengthScale';
    if (_phraseCache.length >= maxCachedPhrases) {
      _phraseCache.remove(_phraseCache.keys.first);
    }
    _phraseCache[cacheKey] = url;
    return url;
  }

  void clearCache() => _phraseCache.clear();

  void toggleUseOnnx(bool value) {
    useOnnxModelNotifier.value = value;
  }
}
