import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Сервис управления E2EE ключами и инициализацией olm.
class KeysService {
  final Client _client;

  KeysService(this._client);

  /// Глобальный флаг: был ли olm инициализирован вручную
  static bool _olmPreInitialized = false;

  /// Cryptography initialization handled by Matrix SDK 7.x internally (vodozemac).
  /// We initialize vodozemac in main.dart before creating the Client.
  /// This method is kept for compatibility but is a no-op.
  static Future<void> ensureOlmInit() async {
    if (kIsWeb && !_olmPreInitialized) {
      try {
        debugPrint('[Matrix] WEB: Crypto is handled by Matrix SDK 7.x internally');
        _olmPreInitialized = true;
      } catch (e) {
        debugPrint('[Matrix] WEB: Crypto init check failed: $e');
      }
    }
  }

  /// Запрос ключей расшифровки для всех зашифрованных комнат.
  /// Вызывается после первого sync, чтобы новое устройство могло расшифровать историю.
  Future<void> requestKeysForEncryptedRooms() async {
    if (!_client.encryptionEnabled) return;

    try {
      final encryptedRooms = _client.rooms.where(
        (room) => room.getState('m.room.encryption') != null,
      );

      for (final room in encryptedRooms) {
        try {
          final lastEvent = room.lastEvent;
          if (lastEvent != null &&
              (lastEvent.type == EventTypes.Encrypted ||
               lastEvent.messageType == MessageTypes.BadEncrypted)) {
            debugPrint('[E2EE] Requesting key for room ${room.id} via event.requestKey()');
            await lastEvent.requestKey();
          }
        } catch (e) {
          debugPrint('[E2EE] Key request failed for room ${room.id}: $e');
        }
      }
    } catch (e) {
      debugPrint('[E2EE] Error requesting keys: $e');
    }
  }
}
