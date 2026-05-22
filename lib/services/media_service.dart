import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:http/http.dart' as http;
import 'lru_image_cache.dart';

/// Сервис загрузки и кеширования медиафайлов.
/// Выделен из chat_room_screen.dart для переиспользования и управления памятью.
class MediaService {
  final Client _client;
  final LruImageCache _imageCache = LruImageCache(maxItems: 100, maxBytes: 50 * 1024 * 1024);

  /// Дедупликация параллельных загрузок одного и того же изображения
  final Map<String, Future<Uint8List?>> _loadFutures = {};

  MediaService(this._client);

  /// LRU-кеш (публичный readonly доступ для fullscreen и др.)
  LruImageCache get cache => _imageCache;

  // ==================== ПРОВЕРКА ТИПА ====================

  /// Проверяет, являются ли байты изображением по magic number
  static bool looksLikeImage(Uint8List bytes) {
    if (bytes.length < 4) return false;
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return true;
    // GIF: 47 49 46
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    // WEBP/RIFF: 52 49 46 46
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) return true;
    // BMP: 42 4D
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    return false;
  }

  /// Проверяет, является ли событие зашифрованным медиа
  static bool isEncryptedMedia(Event event) => event.content.containsKey('file');

  // ==================== ЗАГРУЗКА ИЗОБРАЖЕНИЙ ====================

  /// Получить байты изображения: сначала из кеша, затем загрузить
  Future<Uint8List?> getImageBytes(Event event) async {
    final eventId = event.eventId;

    // Проверяем кеш
    final cached = _imageCache.get(eventId);
    if (cached != null) return cached;

    // Дедупликация: если уже загружается — ждём тот же Future
    return _loadFutures.putIfAbsent(eventId, () async {
      try {
        final bytes = await _loadImageAllMethods(event);
        if (bytes != null) {
          _imageCache.put(eventId, bytes);
        }
        return bytes;
      } finally {
        _loadFutures.remove(eventId);
      }
    });
  }

  /// Попробовать все методы загрузки по очереди
  Future<Uint8List?> _loadImageAllMethods(Event event) async {
    debugPrint("[IMAGE] Event ${event.eventId}, encrypted=${isEncryptedMedia(event)}, mxc=${event.attachmentMxcUrl}");

    // Метод 1: Authenticated media download (MSC3916)
    try {
      final bytes = await authenticatedMediaDownload(event);
      if (bytes != null && looksLikeImage(bytes)) return bytes;
    } catch (_) {}

    // Метод 2: SDK downloadAndDecryptAttachment
    try {
      final file = await event.downloadAndDecryptAttachment();
      if (looksLikeImage(file.bytes)) return file.bytes;
    } catch (_) {}

    // Метод 3: Legacy media download (v3)
    try {
      final bytes = await legacyMediaDownload(event);
      if (bytes != null && looksLikeImage(bytes)) return bytes;
    } catch (_) {}

    return null;
  }

  // ==================== СКАЧИВАНИЕ МЕДИА ====================

  /// Authenticated media download (MSC3916 / v1 endpoint)
  Future<Uint8List?> authenticatedMediaDownload(Event event) async {
    final mxcUrl = event.attachmentMxcUrl;
    final homeserver = _client.homeserver;
    final accessToken = _client.accessToken;
    if (mxcUrl == null || homeserver == null || accessToken == null) return null;

    final serverName = mxcUrl.host;
    final mediaId = mxcUrl.pathSegments.join('/');
    final url = '${homeserver.scheme}://${homeserver.host}/_matrix/client/v1/media/download/$serverName/$mediaId';

    final response = await http.get(Uri.parse(url), headers: {'Authorization': 'Bearer $accessToken'});
    if (response.statusCode == 200) return Uint8List.fromList(response.bodyBytes);
    return null;
  }

  /// Legacy media download (v3 endpoint, with/without token)
  Future<Uint8List?> legacyMediaDownload(Event event) async {
    final mxcUrl = event.attachmentMxcUrl;
    final homeserver = _client.homeserver;
    final accessToken = _client.accessToken;
    if (mxcUrl == null || homeserver == null || accessToken == null) return null;

    final serverName = mxcUrl.host;
    final mediaId = mxcUrl.pathSegments.join('/');

    for (final useToken in [true, false]) {
      try {
        final url = '${homeserver.scheme}://${homeserver.host}/_matrix/media/v3/download/$serverName/$mediaId${useToken ? '?access_token=$accessToken' : ''}';
        final response = await http.get(Uri.parse(url), headers: {'Authorization': 'Bearer $accessToken'});
        if (response.statusCode == 200) return Uint8List.fromList(response.bodyBytes);
      } catch (_) {}
    }
    return null;
  }
}
