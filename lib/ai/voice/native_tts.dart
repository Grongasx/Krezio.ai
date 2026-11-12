import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The system's own voice (Android/iOS TTS, Web Speech, Windows SAPI).
abstract class NativeTts {
  /// Completes when speech finishes or stops, and throws on playback failure.
  Future<void> speak(String text, {double rate = 1.0, double volume = 1.0});
  Future<void> stop();
}

/// Low-level wrapper over `flutter_tts` so [FlutterNativeTts] can be tested
/// directly against Web (`null` return), Android (`1`/`0`), and error events.
abstract class TtsBackend {
  Future<List<String>> getEngines();
  Future<void> setEngine(String engine);
  Future<void> setLanguage(String language);
  Future<void> awaitSpeakCompletion(bool value);
  void setCompletionHandler(VoidCallback handler);
  void setErrorHandler(void Function(dynamic message) handler);
  Future<List<Map<String, String>>> getVoices();
  Future<void> setVoice(Map<String, String> voice);
  Future<void> setPitch(double pitch);
  Future<void> setSpeechRate(double rate);
  Future<void> setVolume(double volume);
  Future<dynamic> speak(String text);
  Future<void> stop();
}

class _FlutterTtsBackend implements TtsBackend {
  final FlutterTts _tts = FlutterTts();

  @override
  Future<List<String>> getEngines() async {
    final raw = await _tts.getEngines as List?;
    return raw == null ? const [] : [for (final e in raw) '$e'];
  }

  @override
  Future<void> setEngine(String engine) => _tts.setEngine(engine);

  @override
  Future<void> setLanguage(String language) => _tts.setLanguage(language);

  @override
  Future<void> awaitSpeakCompletion(bool value) => _tts.awaitSpeakCompletion(value);

  @override
  void setCompletionHandler(VoidCallback handler) => _tts.setCompletionHandler(handler);

  @override
  void setErrorHandler(void Function(dynamic message) handler) => _tts.setErrorHandler(handler);

  @override
  Future<List<Map<String, String>>> getVoices() async {
    final raw = (await _tts.getVoices as List?) ?? const [];
    return [
      for (final v in raw) Map<String, String>.from((v as Map).map((k, x) => MapEntry('$k', '$x'))),
    ];
  }

  @override
  Future<void> setVoice(Map<String, String> voice) => _tts.setVoice(voice);

  @override
  Future<void> setPitch(double pitch) => _tts.setPitch(pitch);

  @override
  Future<void> setSpeechRate(double rate) => _tts.setSpeechRate(rate);

  @override
  Future<void> setVolume(double volume) => _tts.setVolume(volume);

  @override
  Future<dynamic> speak(String text) => _tts.speak(text);

  @override
  Future<void> stop() => _tts.stop();
}

/// A system voice in Portuguese.
class TtsVoice {
  final String name;
  final String locale;
  final bool male;
  final bool local;
  final bool isGoogle;
  final bool isNatural;

  const TtsVoice(
    this.name,
    this.locale, {
    this.male = false,
    this.local = true,
    this.isGoogle = false,
    this.isNatural = false,
  });

  Map<String, String> get asMap => {'name': name, 'locale': locale};
}

/// César is a man: among the system voices in Portuguese, pick Google's male
/// voice by default (`pt-br-x-ptd-network` / `pt-br-x-ptd-local`), or another
/// neural male voice (`Microsoft Antonio Online (Natural)`) when present.
class VoicePicker {
  VoicePicker._();

  static final _maleNames = RegExp(
    r'(?:^|[-_\s])(?:ptd|ptc|wavenet-b|neural2-b|standard-b|journey-d|faber)(?:[-_\s]|$)|\bmale\b|masculin|\bdaniel\b|\bfelipe\b|\bant[oô]nio\b|\bdonato\b|\bhumberto\b|\bf[aá]bio\b|\bnicolau\b|\bval[eé]rio\b|\bricardo\b|\bjulio\b',
    caseSensitive: false,
  );
  static final _femaleNames = RegExp(
    r'female|feminin|\bmaria\b|\bluciana\b|\bfrancisca\b|\bvit[oó]ria\b|\bthalita\b|\bleila\b|\bbrenda\b|\byara\b|(?:^|[-_\s])(?:afs|pte|wavenet-a|wavenet-c|neural2-a|neural2-c)(?:[-_\s]|$)',
    caseSensitive: false,
  );
  static final _googleNames = RegExp(
    r'(?:^|[-_\s])(?:ptd|ptc|afs|pte|wavenet|neural2|journey)(?:[-_\s]|$)|google',
    caseSensitive: false,
  );
  static final _naturalNames = RegExp(
    r'natural|neural|wavenet|journey|studio|online|(?:ptd|ptc)-network|\bant[oô]nio\b|\bhumberto\b|\bdonato\b',
    caseSensitive: false,
  );

  /// Portuguese voices (Brazilian Google male first), each marked male, Google and natural/neural.
  static List<TtsVoice> portuguese(List<Map<String, String>> raw) {
    final out = <TtsVoice>[];
    for (final v in raw) {
      final name = v['name'] ?? '';
      final locale = (v['locale'] ?? '').replaceAll('_', '-');
      if (!locale.toLowerCase().startsWith('pt') || name.isEmpty) continue;
      if ((v['features'] ?? '').contains('notInstalled')) continue;
      final gender = (v['gender'] ?? '').toLowerCase();
      final male = gender == 'male' || (gender.isEmpty && _maleNames.hasMatch(name) && !_femaleNames.hasMatch(name));
      final isGoogle = _googleNames.hasMatch(name);
      final isLocal = v['network_required'] != '1';
      final isNatural = _naturalNames.hasMatch(name) || (isGoogle && !isLocal);
      out.add(TtsVoice(
        name,
        locale,
        male: male,
        local: isLocal,
        isGoogle: isGoogle,
        isNatural: isNatural,
      ));
    }
    int rank(TtsVoice v) =>
        (v.locale.toLowerCase() == 'pt-br' ? 0 : 4) +
        (v.male ? 0 : 8) +
        (v.local ? 0 : 2) +
        (v.isGoogle ? 0 : 1);
    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }

  /// The voice to use: the one the user chose, else Google's male voice (or best male voice).
  /// When [preferNatural] is true, prioritizes Neural / WaveNet HD male voices over offline concatenative ones.
  static TtsVoice? choose(List<TtsVoice> voices, {String? chosen, bool preferNatural = false}) {
    if (chosen != null) {
      for (final v in voices) {
        if (v.name == chosen) return v;
      }
    }
    if (preferNatural) {
      for (final v in voices) {
        if (v.male && v.isGoogle && v.isNatural) return v;
      }
      for (final v in voices) {
        if (v.male && v.isNatural) return v;
      }
    }
    for (final v in voices) {
      if (v.male && v.isGoogle) return v;
    }
    for (final v in voices) {
      if (v.male) return v;
    }
    return null;
  }

  /// Splits multi-sentence text into natural conversational breath clauses so the
  /// TTS engine resets its prosody contour per sentence instead of reading flat.
  static List<String> splitIntoNaturalClauses(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    final parts = trimmed
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? [trimmed] : parts;
  }
}

class FlutterNativeTts implements NativeTts {
  static const prefVoice = 'krezio_voice_name';
  static const googleEngine = 'com.google.android.tts';
  static const defaultGoogleMaleVoice = 'pt-br-x-ptd-local';
  static const defaultGoogleNaturalMaleVoice = 'pt-br-x-ptd-network';

  final TtsBackend _tts;
  final bool _isWeb;
  final TargetPlatform? _platformOverride;

  FlutterNativeTts({
    @visibleForTesting TtsBackend? backend,
    @visibleForTesting bool? isWebOverride,
    @visibleForTesting TargetPlatform? platformOverride,
  })  : _tts = backend ?? _FlutterTtsBackend(),
        _isWeb = isWebOverride ?? kIsWeb,
        _platformOverride = platformOverride;

  TargetPlatform get _platform => _platformOverride ?? defaultTargetPlatform;

  bool _ready = false;
  bool _voiceMatched = false;
  Future<void>? _initializing;
  Completer<bool>? _current;
  Completer<bool>? _clauseCompleter;
  bool _lastClauseCompleted = false;

  /// Pitch used when no male voice exists: subtle warm resonance (< 1.0) without
  /// phase-vocoder metallic distortion.
  static const fallbackPitch = 0.94;
  static const naturalMalePitch = 0.98;
  static const questionMalePitch = 1.02;

  /// Base speech rate on Android/Desktop for 1.0x user speed (0.65 in flutter_tts
  /// corresponds to ~1.3x in Android TextToSpeech, giving natural brisk speech
  /// instead of the sluggish 0.5 default).
  static const calibratedBaseRate = 0.65;

  /// Converts user-facing multiplier (e.g. 1.0x, 1.25x, 1.5x, 2.0x) into the
  /// engine-specific rate expected by `flutter_tts`.
  static double platformRateFor(double userRate, {bool isWeb = kIsWeb, TargetPlatform? platform}) {
    final p = platform ?? defaultTargetPlatform;
    final clampedUser = userRate.clamp(0.5, 2.0);
    if (isWeb) {
      // Web Speech API uses 1.0 as normal speed; 1.15 gives a natural brisk cadence at 1.0x.
      return (clampedUser * 1.15).clamp(0.5, 2.0);
    }
    if (p == TargetPlatform.iOS || p == TargetPlatform.macOS) {
      return (clampedUser * 0.55).clamp(0.25, 1.0);
    }
    return (clampedUser * calibratedBaseRate).clamp(0.25, 1.0);
  }

  Future<void> _init() async {
    if (_ready) return;
    final initializing = _initializing ??= _configure();
    try {
      await initializing;
    } finally {
      if (identical(_initializing, initializing)) _initializing = null;
    }
  }

  Future<void> _configure() async {
    if (!_isWeb && _platform == TargetPlatform.android) {
      // Force Google Speech Services (`com.google.android.tts`) as the default
      // engine on Android so César uses Google's male voice (`pt-br-x-ptd-local`).
      try {
        final engines = await _tts.getEngines();
        if (engines.isEmpty || engines.contains(googleEngine)) {
          await _tts.setEngine(googleEngine);
        }
      } catch (_) {
        try {
          await _tts.setEngine(googleEngine);
        } catch (_) {}
      }
    }
    await _tts.setLanguage('pt-BR');
    await _tts.awaitSpeakCompletion(true);
    try {
      await _applyVoice();
    } catch (e) {
      debugPrint('[NativeTts] voice selection: $e');
    }

    _tts.setCompletionHandler(() {
      final clause = _clauseCompleter;
      if (clause != null && !clause.isCompleted) clause.complete(true);
    });
    _tts.setErrorHandler((msg) {
      final err = '$msg'.toLowerCase();
      // Ignore 'interrupted' / 'canceled' events fired asynchronously when stop() is called before a new speak().
      if (err.contains('interrupted') || err.contains('canceled') || err.contains('cancelled')) {
        return;
      }
      final clause = _clauseCompleter;
      if (clause != null && !clause.isCompleted) {
        clause.complete(false);
        return;
      }
      _complete(false);
    });
    _ready = true;
  }

  void _complete(bool success) {
    final current = _current;
    if (current != null && !current.isCompleted) current.complete(success);
  }

  /// Portuguese voices of this device.
  Future<List<TtsVoice>> voices() async {
    try {
      return VoicePicker.portuguese(await _tts.getVoices());
    } catch (e) {
      debugPrint('[NativeTts] voices: $e');
      return const [];
    }
  }

  Future<void> _applyVoice({bool forceLocal = false}) async {
    final chosen = (await SharedPreferences.getInstance()).getString(prefVoice);
    var available = await voices();
    if (available.isEmpty) {
      // Web Speech and Android TTS bind asynchronously; wait briefly for voice list.
      await Future.delayed(const Duration(milliseconds: 100));
      available = await voices();
    }
    final preferNatural = !forceLocal && (_isWeb || _platform != TargetPlatform.android);
    final candidates = forceLocal
        ? (() {
            final localOnly = available.where((v) => v.local).toList();
            return localOnly.isNotEmpty ? localOnly : available;
          })()
        : available;
    final voice = VoicePicker.choose(
      candidates,
      chosen: forceLocal ? null : chosen,
      preferNatural: preferNatural,
    );
    if (voice != null) {
      await _tts.setVoice(voice.asMap);
      await _tts.setPitch(naturalMalePitch);
      _voiceMatched = true;
    } else {
      _voiceMatched = false;
      if (!_isWeb && _platform == TargetPlatform.android) {
        try {
          await _tts.setVoice(const {'name': defaultGoogleMaleVoice, 'locale': 'pt-BR'});
          await _tts.setPitch(naturalMalePitch);
          return;
        } catch (_) {}
      }
      // Subtle warm masculine pitch when no explicit male voice is reported yet.
      await _tts.setPitch(fallbackPitch);
    }
  }

  /// Saves [name] as César's voice (null = pick automatically) and uses it.
  Future<void> useVoice(String? name) async {
    final p = await SharedPreferences.getInstance();
    name == null ? await p.remove(prefVoice) : await p.setString(prefVoice, name);
    _voiceMatched = false;
    await _init();
    await _applyVoice();
  }

  @override
  Future<void> speak(String text, {double rate = 1.0, double volume = 1.0}) async {
    final outcome = Completer<bool>();
    _current = outcome;
    try {
      unawaited(_startSpeech(outcome, text, rate, volume));
      final played = await outcome.future.timeout(
        Duration(seconds: 10 + text.length ~/ 6),
        onTimeout: () async {
          await stop().timeout(const Duration(seconds: 1), onTimeout: () {});
          return false;
        },
      );
      if (!played) throw StateError('A voz do sistema não conseguiu falar.');
    } finally {
      if (identical(_current, outcome)) _current = null;
    }
  }

  Future<void> _startSpeech(Completer<bool> outcome, String text, double rate, double volume) async {
    try {
      await _init();
      if (!_voiceMatched) {
        try {
          await _applyVoice();
        } catch (_) {}
      }
      if (!identical(_current, outcome)) return;
      await _tts.setSpeechRate(platformRateFor(rate, isWeb: _isWeb, platform: _platform));
      await _tts.setVolume(volume);
      if (!identical(_current, outcome)) return;

      final clauses = VoicePicker.splitIntoNaturalClauses(text);
      final segments = clauses.isEmpty ? [text] : clauses;

      for (final clause in segments) {
        if (!identical(_current, outcome)) return;
        final isQuestion = clause.trimRight().endsWith('?');
        if (_voiceMatched) {
          await _tts.setPitch(isQuestion ? questionMalePitch : naturalMalePitch);
        }

        var ok = await _speakClause(outcome, clause);

        // Fallback to local voice ONLY if the engine rejected synthesis before playing;
        // never replay a clause that already completed/played audio.
        if (!ok && !_lastClauseCompleted && identical(_current, outcome)) {
          try {
            await _applyVoice(forceLocal: true);
            if (!identical(_current, outcome)) return;
            ok = await _speakClause(outcome, clause);
          } catch (_) {}
        }

        if (!ok) {
          if (!outcome.isCompleted) outcome.complete(false);
          return;
        }
      }

      if (!outcome.isCompleted) outcome.complete(true);
    } catch (_) {
      if (!outcome.isCompleted) outcome.complete(false);
    }
  }

  Future<bool> _speakClause(Completer<bool> outcome, String clause) async {
    if (!identical(_current, outcome)) return false;
    _lastClauseCompleted = false;
    final clauseDone = Completer<bool>();
    _clauseCompleter = clauseDone;
    final sw = Stopwatch()..start();
    try {
      final speakFuture = _tts.speak(clause).then<dynamic>((v) => v, onError: (_) => 0);
      // Race with clauseDone so Web `utterance.onError` (which discards
      // flutter_tts_web's completer without resolving it) cannot hang.
      final firstResult = await Future.any<dynamic>([speakFuture, clauseDone.future]);
      sw.stop();

      if (clauseDone.isCompleted) {
        final doneOk = await clauseDone.future;
        if (doneOk) {
          _lastClauseCompleted = true;
          return identical(_current, outcome);
        }
        if (sw.elapsedMilliseconds >= 400) _lastClauseCompleted = true;
        return false;
      }

      // `flutter_tts_web` resolves `await speak(...)` with `null` after
      // `utterance.onEnd`, while native platforms return `1` or `true`.
      final explicitFailure = firstResult != null && firstResult != 1 && firstResult != true;
      if (explicitFailure) {
        if (!clauseDone.isCompleted) clauseDone.complete(false);
        return false;
      }

      final minSpeechMs = (clause.length * 25).clamp(150, 1500);
      final waitDuration = sw.elapsedMilliseconds < minSpeechMs
          ? Duration(seconds: 8 + clause.length ~/ 4)
          : const Duration(milliseconds: 80);
      final finishedOk = await clauseDone.future.timeout(
        waitDuration,
        onTimeout: () => true,
      );
      if (finishedOk) {
        _lastClauseCompleted = true;
      } else if (sw.elapsedMilliseconds >= 400) {
        _lastClauseCompleted = true;
      }
      return finishedOk && identical(_current, outcome);
    } finally {
      sw.stop();
      if (identical(_clauseCompleter, clauseDone)) _clauseCompleter = null;
    }
  }

  @override
  Future<void> stop() async {
    final clause = _clauseCompleter;
    if (clause != null && !clause.isCompleted) clause.complete(false);
    _clauseCompleter = null;
    _complete(false);
    _current = null;
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
