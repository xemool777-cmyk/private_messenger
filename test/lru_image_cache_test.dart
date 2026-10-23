import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/services/lru_image_cache.dart';

Uint8List bytes(int length, [int fill = 0]) =>
    Uint8List.fromList(List<int>.filled(length, fill));

void main() {
  group('LruImageCache', () {
    test('добавление и получение значения', () {
      final cache = LruImageCache(maxItems: 10, maxBytes: 1024);
      final value = bytes(4, 7);

      cache.put('a', value);

      expect(cache.get('a'), same(value));
      expect(cache.containsKey('a'), isTrue);
      expect(cache.length, 1);
      expect(cache.totalBytes, 4);
    });

    test('отсутствующий ключ возвращает null', () {
      final cache = LruImageCache();

      expect(cache.get('missing'), isNull);
      expect(cache.containsKey('missing'), isFalse);
      expect(cache.length, 0);
      expect(cache.totalBytes, 0);
    });

    test('повторная вставка обновляет значение и размер без дублирования', () {
      final cache = LruImageCache();

      cache.put('a', bytes(4));
      cache.put('a', bytes(10, 1));

      expect(cache.length, 1);
      expect(cache.totalBytes, 10);
      expect(cache.get('a')!.length, 10);
    });

    test('вытеснение при превышении лимита по количеству элементов', () {
      final cache = LruImageCache(maxItems: 2, maxBytes: 1024);

      cache.put('a', bytes(1));
      cache.put('b', bytes(1));
      cache.put('c', bytes(1));

      expect(cache.length, 2);
      expect(cache.containsKey('a'), isFalse);
      expect(cache.containsKey('b'), isTrue);
      expect(cache.containsKey('c'), isTrue);
      expect(cache.totalBytes, 2);
    });

    test('вытеснение при превышении лимита по размеру в байтах', () {
      final cache = LruImageCache(maxItems: 100, maxBytes: 10);

      cache.put('a', bytes(4));
      cache.put('b', bytes(4));
      cache.put('c', bytes(4));

      expect(cache.length, 2);
      expect(cache.containsKey('a'), isFalse);
      expect(cache.containsKey('b'), isTrue);
      expect(cache.containsKey('c'), isTrue);
      expect(cache.totalBytes, 8);
    });

    test('самый давний элемент вытесняется первым', () {
      final cache = LruImageCache(maxItems: 2, maxBytes: 1024);

      cache.put('a', bytes(1));
      cache.put('b', bytes(1));
      cache.put('c', bytes(1));

      expect(cache.containsKey('a'), isFalse);
      expect(cache.containsKey('b'), isTrue);
      expect(cache.containsKey('c'), isTrue);
    });

    test('получение значения обновляет LRU-позицию', () {
      final cache = LruImageCache(maxItems: 2, maxBytes: 1024);

      cache.put('a', bytes(1));
      cache.put('b', bytes(1));
      cache.get('a');
      cache.put('c', bytes(1));

      expect(cache.containsKey('a'), isTrue);
      expect(cache.containsKey('b'), isFalse);
      expect(cache.containsKey('c'), isTrue);
      expect(cache.length, 2);
    });

    test('containsKey не обновляет LRU-позицию', () {
      final cache = LruImageCache(maxItems: 2, maxBytes: 1024);

      cache.put('a', bytes(1));
      cache.put('b', bytes(1));
      cache.containsKey('a');
      cache.put('c', bytes(1));

      expect(cache.containsKey('a'), isFalse);
      expect(cache.containsKey('b'), isTrue);
      expect(cache.containsKey('c'), isTrue);
    });

    test('элемент больше maxBytes не остаётся в кеше', () {
      final cache = LruImageCache(maxItems: 10, maxBytes: 5);

      cache.put('huge', bytes(6));

      expect(cache.length, 0);
      expect(cache.totalBytes, 0);
      expect(cache.get('huge'), isNull);
    });
  });
}
