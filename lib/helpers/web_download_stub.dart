import 'dart:typed_data';

/// Заглушки для не-web платформ. Реальная реализация в web_download_web.dart.

bool canPlayAudioType(String mime) => false;

String createObjectUrlFromBytes(Uint8List bytes, String mime) => '';

void revokeObjectUrl(String url) {}

void downloadUrl(String url, String filename) {}

/// Заглушка web-аудиоплеера.
class WebAudioPlayer {
  WebAudioPlayer._();

  factory WebAudioPlayer.fromUrl(
    String url, {
    void Function()? onEnded,
    void Function()? onError,
  }) =>
      WebAudioPlayer._();

  double get duration => 0;
  double get currentTime => 0;
  bool get isPaused => true;

  void load() {}
  Future<void> play() async {}
  void pause() {}
  void remove() {}
}

Future<String?> extractVideoThumbnail(
  Uint8List bytes,
  String mimeType, {
  Duration timeout = const Duration(seconds: 10),
}) async =>
    null;

void playVideoFullscreen(Uint8List bytes, String mimeType) {}
