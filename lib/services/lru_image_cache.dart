import 'dart:collection';
import 'dart:typed_data';

/// LRU-кеш изображений с лимитом по размеру и количеству элементов.
/// Использует LinkedHashMap для LRU-порядка (access order).
class LruImageCache {
  final int maxItems;
  final int maxBytes;
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  int _totalBytes = 0;

  LruImageCache({this.maxItems = 100, this.maxBytes = 50 * 1024 * 1024});

  /// Получить изображение из кеша (обновляет LRU-позицию)
  Uint8List? get(String key) {
    if (!_cache.containsKey(key)) return null;
    // Перемещаем в конец (most recently used)
    final value = _cache.remove(key)!;
    _cache[key] = value;
    return value;
  }

  /// Положить изображение в кеш
  void put(String key, Uint8List bytes) {
    // Если уже есть — удаляем старое (обновим размер)
    if (_cache.containsKey(key)) {
      final oldBytes = _cache.remove(key)!;
      _totalBytes -= oldBytes.length;
    }

    _cache[key] = bytes;
    _totalBytes += bytes.length;

    _evict();
  }

  /// Проверить наличие в кеше (без обновления LRU)
  bool containsKey(String key) => _cache.containsKey(key);

  /// Текущий размер кеша в байтах
  int get totalBytes => _totalBytes;

  /// Количество элементов
  int get length => _cache.length;

  /// Очистка по LRU: удаляем старые элементы пока не уложимся в лимиты
  void _evict() {
    while ((_cache.length > maxItems || _totalBytes > maxBytes) && _cache.isNotEmpty) {
      final oldestKey = _cache.keys.first;
      final removed = _cache.remove(oldestKey)!;
      _totalBytes -= removed.length;
    }
  }
}
