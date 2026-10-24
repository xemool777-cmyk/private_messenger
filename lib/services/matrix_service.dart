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

  /// Инициализация: создаёт клиент и все подсервисы.
  ///
  /// Каждый шаг ограничен таймаутом и не прерывает инициализацию целиком:
  /// при сбое шага приложение продолжает работу в деградированном режиме.
  Future<void> init() async {
    const stepTimeout = Duration(seconds: 10);
    var failedSteps = 0;

    // 1. Инициализируем vodozemac (нативные библиотеки / WASM)
    try {
      await KeysService.ensureVodozemacInit().timeout(stepTimeout);
      print('[INIT] vodozemac ok');
    } on TimeoutException {
      failedSteps++;
      print('[INIT] vodozemac timeout — продолжаем без E2EE');
    } catch (e) {
      failedSteps++;
      print('[INIT] vodozemac ошибка: $e — продолжаем без E2EE');
    }

    // 2. База данных. При сбое создаём Client без database.
    dynamic db;
    try {
      db = await MatrixSdkDatabase.init('private_messenger_db')
          .timeout(stepTimeout);
      print('[INIT] database ok');
    } on TimeoutException {
      failedSteps++;
      db = null;
      print('[INIT] database timeout — создаём Client без базы данных');
    } catch (e) {
      failedSteps++;
      db = null;
      print(
          '[INIT] database ошибка: $e — создаём Client без базы данных');
    }

    // 3. Создаём Matrix клиент с базой данных и нативными реализациями
    Client? client;
    try {
      client = await Future<Client>.sync(
        () => Client(
          'PrivateMessenger',
          database: db,
          nativeImplementations: KeysService.createNativeImplementations(),
        ),
      ).timeout(stepTimeout);
      print('[INIT] client ok');
    } on TimeoutException {
      failedSteps++;
      print('[INIT] client timeout');
    } catch (e) {
      failedSteps++;
      print('[INIT] client ошибка: $e — пробуем без native implementations');
    }

    if (client == null) {
      try {
        client = Client('PrivateMessenger', database: db);
        print('[INIT] client fallback ok');
      } catch (e) {
        failedSteps++;
        print('[INIT] client fallback ошибка: $e');
        // Без базы Client создать нельзя (database обязателен в SDK 7.x):
        // оставляем client == null — UI покажет ошибку и кнопку «Повторить».
      }
    }

    if (client == null) {
      print('[INIT] завершено, шагов с ошибкой: $failedSteps');
      return;
    }
    _client = client;

    // 4. Инициализация клиента
    try {
      await _client.init().timeout(stepTimeout);
      print('[INIT] client.init ok');
    } on TimeoutException {
      failedSteps++;
      print('[INIT] client.init timeout — продолжаем');
    } catch (e) {
      failedSteps++;
      print('[INIT] client.init ошибка: $e — продолжаем');
    }

    // 5. Создаём подсервисы (KeysService первый — нужен AuthService)
    try {
      keys = KeysService(_client);
      auth = AuthService(_client, keys: keys);
      media = MediaService(_client);
      call = CallService(_client);
      sync = SyncService(_client, keys: keys, callService: call);
      print('[INIT] sub-services ok');
    } catch (e) {
      failedSteps++;
      print('[INIT] sub-services ошибка: $e');
    }

    // 6. Инициализируем CallService
    try {
      await Future<void>.sync(() => call.init()).timeout(stepTimeout);
      print('[INIT] call.init ok');
    } on TimeoutException {
      failedSteps++;
      print('[INIT] call.init timeout — продолжаем');
    } catch (e) {
      failedSteps++;
      print('[INIT] call.init ошибка: $e — продолжаем');
    }

    // 7. Если уже залогинен — переподключаемся и восстанавливаем сессию
    if (_client.isLogged()) {
      try {
        await _client
            .checkHomeserver(Uri.parse(AppConfig.homeserverUrl))
            .timeout(stepTimeout);
        print('[INIT] homeserver reconnect ok');
      } on TimeoutException {
        failedSteps++;
        print('[INIT] homeserver reconnect timeout — продолжаем');
      } catch (e) {
        failedSteps++;
        print('[INIT] homeserver reconnect ошибка: $e — продолжаем');
      }

      try {
        await auth.resumeSession().timeout(stepTimeout);
        print('[INIT] session resume ok');
      } on TimeoutException {
        failedSteps++;
        print('[INIT] session resume timeout — продолжаем');
      } catch (e) {
        failedSteps++;
        print('[INIT] session resume ошибка: $e — продолжаем');
      }
    }

    // 8. Запускаем синхронизацию ДО crypto init — SDK нужно знать state сервера.
    // Вместо безусловной задержки ждём первый sync с таймаутом.
    try {
      sync.startListening();
      if (_client.isLogged()) {
        await _client.onSync.stream.first.timeout(stepTimeout);
      }
      print('[INIT] sync ok');
    } on TimeoutException {
      failedSteps++;
      print('[INIT] sync timeout — продолжаем без ожидания первого sync');
    } catch (e) {
      failedSteps++;
      print('[INIT] sync ошибка: $e — продолжаем');
    }

    // 9. Настраиваем crypto identity с ретраем и key backup верификацией.
    // Без vodozemac E2EE недоступно — не ждём crypto-операции впустую.
    if (!KeysService.vodozemacReady) {
      print('[INIT] crypto identity ok (пропущено: E2EE выключено)');
    } else {
      try {
        final e2eeReady = await keys
            .setupCryptoIdentityWithRetry()
            .timeout(stepTimeout);
        if (e2eeReady) {
          print('[INIT] crypto identity ok');
        } else {
          failedSteps++;
          print(
              '[INIT] crypto identity ошибка: E2EE недоступно — продолжаем без шифрования');
        }
      } on TimeoutException {
        failedSteps++;
        print(
            '[INIT] crypto identity timeout — продолжаем без шифрования');
      } catch (e) {
        failedSteps++;
        print(
            '[INIT] crypto identity ошибка: $e — продолжаем без шифрования');
      }
    }

    // 10. E2EE диагностика
    debugPrint('[INIT] encryptionEnabled = ${_client.encryptionEnabled}');

    // 11. Слушаем ошибки UIA (пароль недоступен)
    try {
      KeysService.onUiaFailed.addListener(() {
        final msg = KeysService.onUiaFailed.value;
        if (msg != null) {
          debugPrint('[E2EE] ⚠️ UIA FAILURE: $msg');
        }
      });
      print('[INIT] uia listener ok');
    } catch (e) {
      failedSteps++;
      print('[INIT] uia listener ошибка: $e');
    }

    // 12. Инициализируем сервис уведомлений
    try {
      await NotificationService.instance.init().timeout(stepTimeout);
      print('[INIT] notifications ok');
    } on TimeoutException {
      failedSteps++;
      print('[INIT] notifications timeout — продолжаем');
    } catch (e) {
      failedSteps++;
      print('[INIT] notifications ошибка: $e — продолжаем');
    }

    debugPrint('[INIT] MatrixService initialization complete');
    print('[INIT] завершено, шагов с ошибкой: $failedSteps');
  }

  /// Подключение к homeserver с ретраем
  Future<void> connectToHomeserver() => auth.connectToHomeserver();

  /// Логин пользователя
  Future<void> login(String username, String password) =>
      auth.login(username, password);

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
  Future<({bool initialized, bool connected})?>
      checkCryptoIdentityState() async {
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
