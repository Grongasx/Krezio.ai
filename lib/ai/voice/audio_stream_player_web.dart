// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

class AudioStreamPlayer {
  static html.AudioElement? _currentAudio;

  static Future<bool> playUrl(String url, {void Function()? onCompletion, void Function(dynamic)? onError}) async {
    try {
      stop();

      final audio = html.AudioElement(url);
      _currentAudio = audio;

      audio.onEnded.listen((_) {
        if (identical(_currentAudio, audio)) onCompletion?.call();
      });

      audio.onError.listen((e) {
        if (identical(_currentAudio, audio)) onError?.call(e);
      });

      await audio.play();
      return identical(_currentAudio, audio);
    } catch (e) {
      onError?.call(e);
      return false;
    }
  }

  static void stop() {
    final audio = _currentAudio;
    _currentAudio = null;
    try {
      audio?.pause();
      // Cancel an in-flight playback request as well as audio already playing.
      audio?.removeAttribute('src');
      audio?.load();
    } catch (_) {}
  }
}
