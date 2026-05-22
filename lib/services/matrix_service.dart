import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../config/app_config.dart';
import 'auth_service.dart';
import 'sync_service.dart';
import 'keys_service.dart';
import 'media_service.dart';
import 'notification_service.dart';

/// Фасад для всех Matrix-сервисов.
/// Сохраняет обратную совместимость: экраны продолжают работать через MatrixService.
/// Внутренняя логика делегирована AuthService, SyncService, KeysService, MediaService.
class MatrixService {
  late final Client _client;
  late final AuthService auth;
  late final SyncService sync;
  late final KeysService keys;
  late final MediaService media;

  Client get client => _client;
  String get userId => auth.userId;
  bool get isLogged => auth.isLogged;
  String? get currentRoomId => sync.currentRoomId;
  set currentRoomId(String? v) => sync.currentRoomId = v;

  /// Обратная совместимость: статические методы делегируют в AppConfig
  static String get homeserverUrl => AppConfig.homeserverUrl;
  static String get serverName => AppConfig.serverName;
  static String buildUserId(String username) => AppConfig.buildUserId(username);

  /// Инициализация: создаёт клиент и все подсервисы
  Future<void> init() async {
    // 1. Pre-init olm (критично для E2EE на web)
    await KeysService.ensureOlmInit();

    // 2. Создаём Matrix клиент с базой данных (MatrixSdkDatabase использует IndexedDB на web)
    final db = await MatrixSdkDatabase.init('private_messenger_db');
    _client = Client('PrivateMessenger', database: db);

    // 3. Инициализация клиента
    try {
      await _client.init();
    } catch (e) {
      debugPrint('[Matrix] Client.init() error: $e');
    }

    // 4. Создаём подсервисы
    keys = KeysService(_client);
    auth = AuthService(_client);
    media = MediaService(_client);
    sync = SyncService(_client, keys: keys);

    // 5. Если уже залогинен — переподключаемся к homeserver
    if (_client.isLogged()) {
      try {
        await _client.checkHomeserver(Uri.parse(AppConfig.homeserverUrl));
        debugPrint('[Matrix] Homeserver reconnected for existing session');
      } catch (e) {
        debugPrint('[Matrix] Failed to reconnect homeserver: $e');
      }
    }

    // 6. E2EE диагностика
    if (_client.encryptionEnabled) {
      debugPrint('[Matrix] Identity key: ${_client.identityKey}');
      debugPrint('[Matrix] Fingerprint key: ${_client.fingerprintKey}');
    }

    // 7. Инициализируем сервис уведомлений
    await NotificationService.instance.init();

    // 8. Запускаем синхронизацию (слушает onSync)
    sync.startListening();
  }

  /// Подключение к homeserver с ретраем
  Future<void> connectToHomeserver() => auth.connectToHomeserver();

  /// Логин пользователя
  Future<void> login(String username, String password) => auth.login(username, password);

  /// Восстановление сессии
  Future<void> resumeSession() => auth.resumeSession();

  /// Выход из аккаунта
  Future<void> logout() => auth.logout();

  void dispose() {
    sync.dispose();
    NotificationService.instance.dispose();
  }
}
