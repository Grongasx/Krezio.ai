import 'audio_stream_player_io.dart'
    if (dart.library.html) 'audio_stream_player_web.dart' as impl;

/// Cross-platform audio player for playing synthesized voice WAV streams.
class AudioStreamPlayer {
  static Future<bool> playUrl(String url, {void Function()? onCompletion, void Function(dynamic)? onError}) {
    return impl.AudioStreamPlayer.playUrl(url, onCompletion: onCompletion, onError: onError);
  }

  static void stop() {
    impl.AudioStreamPlayer.stop();
  }
}
