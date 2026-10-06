// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

class AudioStreamPlayer {
  static html.AudioElement? _currentAudio;

  static Future<bool> playUrl(String url, {void Function()? onCompletion, void Function(dynamic)? onError}) async {
    try {
      _currentAudio?.pause();
      _currentAudio = null;

      final audio = html.AudioElement(url);
      _currentAudio = audio;

      audio.onEnded.listen((_) {
        onCompletion?.call();
      });

      audio.onError.listen((e) {
        onError?.call(e);
      });

      await audio.play();
      return true;
    } catch (e) {
      onError?.call(e);
      return false;
    }
  }

  static void stop() {
    try {
      _currentAudio?.pause();
      _currentAudio = null;
    } catch (_) {}
  }
}
