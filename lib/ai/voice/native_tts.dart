import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// The system's own voice (Android/iOS TTS, Web Speech, Windows SAPI), used
/// when César's neural voice server isn't there — so César always speaks.
abstract class NativeTts {
  /// Speaks [text]; completes when it finishes, is stopped or fails.
  Future<void> speak(String text, {double rate = 1.0, double volume = 1.0});
  Future<void> stop();
}

class FlutterNativeTts implements NativeTts {
  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  Completer<void>? _current;

  Future<void> _init() async {
    if (_ready) return;
    _ready = true;
    try {
      await _tts.setLanguage('pt-BR');
      await _tts.awaitSpeakCompletion(true);
    } catch (e) {
      debugPrint('[NativeTts] init: $e');
    }
    void done() {
      if (_current != null && !_current!.isCompleted) _current!.complete();
    }

    _tts.setCompletionHandler(done);
    _tts.setCancelHandler(done);
    _tts.setErrorHandler((_) => done());
  }

  @override
  Future<void> speak(String text, {double rate = 1.0, double volume = 1.0}) async {
    await _init();
    _current = Completer<void>();
    try {
      // flutter_tts: 0.5 is the normal rate on Android/iOS.
      await _tts.setSpeechRate((rate * 0.5).clamp(0.1, 1.0));
      await _tts.setVolume(volume);
      await _tts.speak(text);
    } catch (e) {
      debugPrint('[NativeTts] speak: $e');
      if (!_current!.isCompleted) _current!.complete();
    }
    return _current!.future.timeout(Duration(seconds: 5 + text.length ~/ 8), onTimeout: () {});
  }

  @override
  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
    if (_current != null && !_current!.isCompleted) _current!.complete();
  }
}
