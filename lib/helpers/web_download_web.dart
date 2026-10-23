import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

/// Web-реализация браузерных операций для сообщений.
/// Для native платформ используется web_download_stub.dart.

/// Проверяет, может ли браузер воспроизвести указанный MIME-тип.
bool canPlayAudioType(String mime) {
  final test = html.AudioElement();
  final result = test.canPlayType(mime);
  test.remove();
  return result.isNotEmpty;
}

/// Создаёт object URL из байтов.
String createObjectUrlFromBytes(Uint8List bytes, String mime) {
  final blob = html.Blob([bytes], mime);
  return html.Url.createObjectUrlFromBlob(blob);
}

void revokeObjectUrl(String url) {
  html.Url.revokeObjectUrl(url);
}

/// Скачивает содержимое object URL под указанным именем.
void downloadUrl(String url, String filename) {
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}

/// Обёртка над html.AudioElement, чтобы не протаскивать dart:html в UI.
class WebAudioPlayer {
  final html.AudioElement _element;

  WebAudioPlayer._(
    this._element, {
    void Function()? onEnded,
    void Function()? onError,
  }) {
    if (onEnded != null) {
      _element.onEnded.listen((_) => onEnded());
    }
    if (onError != null) {
      _element.onError.listen((_) => onError());
    }
  }

  factory WebAudioPlayer.fromUrl(
    String url, {
    void Function()? onEnded,
    void Function()? onError,
  }) {
    return WebAudioPlayer._(
      html.AudioElement(url),
      onEnded: onEnded,
      onError: onError,
    );
  }

  double get duration => _element.duration;
  double get currentTime => _element.currentTime;
  bool get isPaused => _element.paused;

  void load() => _element.load();
  Future<void> play() => _element.play();
  void pause() => _element.pause();
  void remove() => _element.remove();
}

/// Извлекает первый кадр видео через canvas и возвращает data URL.
Future<String?> extractVideoThumbnail(
  Uint8List bytes,
  String mimeType, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final blobUrl = createObjectUrlFromBytes(bytes, mimeType);
  html.VideoElement? video;
  try {
    final element = html.VideoElement()
      ..src = blobUrl
      ..style.display = 'none'
      ..preload = 'metadata';
    video = element;

    html.document.body?.append(element);

    final completer = Completer<String?>();
    element.onLoadedMetadata.listen((_) {
      element.currentTime = element.duration * 0.1;
    });
    element.onSeeked.listen((_) {
      try {
        final canvas = html.CanvasElement(width: 200, height: 140);
        final ctx = canvas.context2D;
        ctx.drawImageScaled(element, 0, 0, 200, 140);
        if (!completer.isCompleted) {
          completer.complete(canvas.toDataUrl('image/jpeg', 0.7));
        }
      } catch (_) {
        if (!completer.isCompleted) completer.complete(null);
      }
    });
    element.onError.listen((_) {
      if (!completer.isCompleted) completer.complete(null);
    });
    Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });

    return await completer.future;
  } finally {
    video?.remove();
    revokeObjectUrl(blobUrl);
  }
}

/// Открывает видео на весь экран из байтов (с автоматической очисткой).
void playVideoFullscreen(Uint8List bytes, String mimeType) {
  final blobUrl = createObjectUrlFromBytes(bytes, mimeType);
  final video = html.VideoElement()
    ..src = blobUrl
    ..controls = true
    ..autoplay = true
    ..style.position = 'fixed'
    ..style.top = '0'
    ..style.left = '0'
    ..style.width = '100%'
    ..style.height = '100%'
    ..style.zIndex = '2147483647'
    ..style.backgroundColor = 'black';

  var cleanedUp = false;
  void cleanup() {
    if (cleanedUp) return;
    cleanedUp = true;
    video.pause();
    video.remove();
    revokeObjectUrl(blobUrl);
  }

  video.onEnded.listen((_) => cleanup());
  video.onError.listen((_) => cleanup());
  html.document.onFullscreenChange.listen((_) {
    if (html.document.fullscreenElement == null) {
      cleanup();
    }
  });

  html.document.body?.append(video);
  try {
    video.requestFullscreen();
  } catch (_) {
    // iOS Safari не поддерживает Fullscreen API — оверлей работает сам
  }
}
