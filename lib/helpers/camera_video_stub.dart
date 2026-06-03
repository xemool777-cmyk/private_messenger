import 'dart:typed_data';

/// Заглушка для не-web платформ. Реальная реализация в camera_video_web.dart.
Future<({Uint8List bytes, String name})?> pickVideoFromCamera() async {
  throw UnsupportedError('pickVideoFromCamera is only available on the web');
}
