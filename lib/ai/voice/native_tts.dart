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

/// A system voice in Portuguese.
class TtsVoice {
  final String name;
  final String locale;
  final bool male;
  final bool local;

  const TtsVoice(this.name, this.locale, {this.male = false, this.local = true});

  Map<String, String> get asMap => {'name': name, 'locale': locale};
}

/// César is a man: among the system voices in Portuguese, pick a male one.
/// Android doesn't say a voice's gender, so known male voices are recognized
/// by name (Google: "pt-br-x-ptd"/"ptc"; Microsoft: "Daniel"; Apple:
/// "Felipe"); iOS and Windows also report the gender. Pure Dart.
class VoicePicker {
  VoicePicker._();

  static final _maleNames = RegExp(r'(?:^|[-_\s])(?:ptd|ptc)(?:[-_\s]|$)|\bmale\b|masculin|\bdaniel\b|\bfelipe\b|\bant[oô]nio\b|\bricardo\b|\bjulio\b',
      caseSensitive: false);
  static final _femaleNames = RegExp(r'female|feminin|\bmaria\b|\bluciana\b|\bfrancisca\b|\bvit[oó]ria\b|(?:^|[-_\s])(?:afs|pte)(?:[-_\s]|$)',
      caseSensitive: false);

  /// Portuguese voices (Brazilian first), each marked male or not.
  static List<TtsVoice> portuguese(List<Map<String, String>> raw) {
    final out = <TtsVoice>[];
    for (final v in raw) {
      final name = v['name'] ?? '';
      final locale = (v['locale'] ?? '').replaceAll('_', '-');
      if (!locale.toLowerCase().startsWith('pt') || name.isEmpty) continue;
      if ((v['features'] ?? '').contains('notInstalled')) continue;
      final gender = (v['gender'] ?? '').toLowerCase();
      final male = gender == 'male' || (gender.isEmpty && _maleNames.hasMatch(name) && !_femaleNames.hasMatch(name));
      out.add(TtsVoice(name, locale, male: male, local: v['network_required'] != '1'));
    }
    int rank(TtsVoice v) => (v.locale.toLowerCase() == 'pt-br' ? 0 : 2) + (v.male ? 0 : 4) + (v.local ? 0 : 1);
    out.sort((a, b) => rank(a).compareTo(rank(b)));
    return out;
  }

  /// The voice to use: the one the user chose, else the best male voice.
  static TtsVoice? choose(List<TtsVoice> voices, {String? chosen}) {
    if (chosen != null) {
      for (final v in voices) {
        if (v.name == chosen) return v;
      }
    }
    for (final v in voices) {
      if (v.male) return v;
    }
    return null;
  }
}

class FlutterNativeTts implements NativeTts {
  static const prefVoice = 'krezio_voice_name';

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  Future<void>? _initializing;
  Completer<bool>? _current;

  /// Pitch used when no male voice exists: a deeper version of the default.
  static const fallbackPitch = 0.8;

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
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // Xiaomi and others ship their own engine as the default, often with
      // no male voice: Google's engine, when installed, has one (pt-br-x-ptd).
      try {
        final engines = ((await _tts.getEngines as List?) ?? const []).map((e) => '$e').toList();
        if (engines.contains('com.google.android.tts')) await _tts.setEngine('com.google.android.tts');
      } catch (_) {
        // The default engine can still speak when engine discovery fails.
      }
    }
    await _tts.setLanguage('pt-BR');
    await _tts.awaitSpeakCompletion(true);
    try {
      await _applyVoice();
    } catch (e) {
      debugPrint('[NativeTts] voice selection: $e');
    }

    _tts.setCompletionHandler(() => _complete(true));
    _tts.setCancelHandler(() => _complete(false));
    _tts.setErrorHandler((_) => _complete(false));
    _ready = true;
  }

  void _complete(bool success) {
    final current = _current;
    if (current != null && !current.isCompleted) current.complete(success);
  }

  /// Portuguese voices of this device.
  Future<List<TtsVoice>> voices() async {
    try {
      final raw = (await _tts.getVoices as List?) ?? const [];
      return VoicePicker.portuguese([for (final v in raw) Map<String, String>.from((v as Map).map((k, x) => MapEntry('$k', '$x')))]);
    } catch (e) {
      debugPrint('[NativeTts] voices: $e');
      return const [];
    }
  }

  Future<void> _applyVoice() async {
    final chosen = (await SharedPreferences.getInstance()).getString(prefVoice);
    final voice = VoicePicker.choose(await voices(), chosen: chosen);
    if (voice != null) {
      await _tts.setVoice(voice.asMap);
      await _tts.setPitch(1.0);
    } else {
      // No male voice on this device: the default one, deeper.
      await _tts.setPitch(fallbackPitch);
    }
  }

  /// Saves [name] as César's voice (null = pick automatically) and uses it.
  Future<void> useVoice(String? name) async {
    final p = await SharedPreferences.getInstance();
    name == null ? await p.remove(prefVoice) : await p.setString(prefVoice, name);
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
        Duration(seconds: 8 + text.length ~/ 8),
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
      if (!identical(_current, outcome)) return;
      // flutter_tts: 0.5 is the normal rate on Android/iOS.
      await _tts.setSpeechRate((rate * 0.5).clamp(0.1, 1.0));
      await _tts.setVolume(volume);
      if (!identical(_current, outcome)) return;
      final result = await _tts.speak(text);
      if (!outcome.isCompleted) outcome.complete(result == 1 || result == true);
    } catch (_) {
      if (!outcome.isCompleted) outcome.complete(false);
    }
  }

  @override
  Future<void> stop() async {
    _complete(false);
    _current = null;
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
