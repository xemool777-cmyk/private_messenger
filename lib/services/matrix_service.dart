import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';

import '../config/app_config.dart';
import 'auth_service.dart';
import 'sync_service.dart';
import 'keys_service.dart';
import 'media_service.dart';
import 'notification_service.dart';
import 'call_service.dart';

/// Фасад для всех Matrix-сервисов.
/// Сохраняет обратную совместимость: экраны продолжают работать через MatrixService.
/// Внутренняя логика делегирована AuthService, SyncService, KeysService, MediaService.
class MatrixService {
  late final Client _client;
  late final AuthService auth;
  late final SyncService sync;
  late final KeysService keys;
  late final MediaService media;
  late final CallService call;

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
    // 1. Инициализируем vodozemac (нативные библиотеки / WASM)
    debugPrint('[INIT] Step 1: Initializing vodozemac...');
    await KeysService.ensureVodozemacInit();
    debugPrint('[INIT] vodozemac OK');

    // 2. Создаём Matrix клиент с базой данных и нативными реализациями
    debugPrint('[INIT] Step 2: Creating Client with NativeImplementations...');
    final db = await MatrixSdkDatabase.init('private_messenger_db');
    _client = Client(
      'PrivateMessenger',
      database: db,
      nativeImplementations: KeysService.createNativeImplementations(),
    );
    debugPrint('[INIT] Client created');

    // 3. Инициализация клиента
    debugPrint('[INIT] Step 3: Client.init()...');
    try {
      await _client.init();
      debugPrint('[INIT] Client.init() OK');
    } catch (e) {
      debugPrint('[Matrix] Client.init() error: $e');
    }

    // 4. Создаём подсервисы (KeysService первый — нужен AuthService)
    keys = KeysService(_client);
    auth = AuthService(_client, keys: keys);
    media = MediaService(_client);
    call = CallService(_client);
    sync = SyncService(_client, keys: keys, callService: call);

    debugPrint('[INIT] Sub-services created');
    debugPrint('[INIT] Initializing CallService...');
    call.init();
    debugPrint('[INIT] CallService OK');

    // 5. Если уже залогинен — переподключаемся и восстанавливаем сессию
    if (_client.isLogged()) {
      debugPrint('[INIT] Existing session detected, reconnecting...');
      try {
        await _client.checkHomeserver(Uri.parse(AppConfig.homeserverUrl));
        debugPrint('[Matrix] Homeserver reconnected for existing session');
      } catch (e) {
        debugPrint('[Matrix] Failed to reconnect homeserver: $e');
      }

      // Восстанавливаем сессию
      await auth.resumeSession();
    }

    // 6. Запускаем синхронизацию ДО crypto init — SDK нужно знать state сервера
    debugPrint('[INIT] Starting sync before crypto init...');
    sync.startListening();
    // Даём sync'у время получить первый state
    await Future.delayed(const Duration(seconds: 3));

    // 7. Настраиваем crypto identity с ретраем и key backup верификацией
    debugPrint('[INIT] Setting up crypto identity (with retry)...');
    final e2eeReady = await keys.setupCryptoIdentityWithRetry();
    if (e2eeReady) {
      debugPrint('[INIT] E2EE is ready');
    } else {
      debugPrint('[INIT] E2EE setup FAILED — continuing without cross-signing');
    }

    // 8. E2EE диагностика
    debugPrint('[INIT] encryptionEnabled = ${_client.encryptionEnabled}');
    if (_client.encryptionEnabled) {
      debugPrint('[Matrix] Identity key: ${_client.identityKey}');
      debugPrint('[Matrix] Fingerprint key: ${_client.fingerprintKey}');
    }

    // 9. Слушаем ошибки UIA (пароль недоступен)
    KeysService.onUiaFailed.addListener(() {
      final msg = KeysService.onUiaFailed.value;
      if (msg != null) {
        debugPrint('[E2EE] ⚠️ UIA FAILURE: $msg');
      }
    });

    // 10. Инициализируем сервис уведомлений
    await NotificationService.instance.init();

    debugPrint('[INIT] MatrixService initialization complete');
  }

  /// Подключение к homeserver с ретраем
  Future<void> connectToHomeserver() => auth.connectToHomeserver();

  /// Логин пользователя
  Future<void> login(String username, String password) => auth.login(username, password);

  /// Восстановление сессии
  Future<void> resumeSession() => auth.resumeSession();

  /// Выход из аккаунта
  Future<void> logout() => auth.logout();

  /// Сбросить и пересоздать crypto identity.
  /// Возвращает новый ключ восстановления или null при ошибке.
  Future<String?> resetCryptoIdentity() => keys.resetCryptoIdentity();

  /// Восстановить crypto identity по ключу восстановления
  /// Возвращает true если успешно (устройство стало доверенным)
  Future<bool> restoreCryptoIdentity(String recoveryKey) async {
    try {
      await _client.restoreCryptoIdentity(recoveryKey);
      await KeysService.persistRecoveryKey(recoveryKey, userId: _client.userID);
      KeysService.setRecoveryKey(recoveryKey);
      debugPrint('[E2EE] Crypto identity RESTORED via recovery key');
      // После восстановления — запрашиваем ключи комнат
      keys.requestKeysForEncryptedRooms();
      return true;
    } catch (e) {
      debugPrint('[E2EE] restoreCryptoIdentity FAILED: $e');
      return false;
    }
  }

  /// Проверить статус crypto identity
  /// Возвращает (initialized, connected) — record из Matrix SDK
  Future<({bool initialized, bool connected})?> checkCryptoIdentityState() async {
    if (!_client.encryptionEnabled) return null;
    try {
      return await _client.getCryptoIdentityState();
    } catch (e) {
      debugPrint('[E2EE] getCryptoIdentityState error: $e');
      return null;
    }
  }

  void dispose() {
    call.dispose();
    sync.dispose();
    NotificationService.instance.dispose();
  }
}
