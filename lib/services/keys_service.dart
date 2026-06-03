import 'dart:async';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;

/// Сервис управления E2EE ключами и инициализацией vodozemac.
///
/// Matrix SDK 7.x требует:
/// 1. vod.init() ДО создания Client
/// 2. NativeImplementationsIsolate с vodozemacInit для нативных платформ
/// 3. initCryptoIdentity() / restoreCryptoIdentity() после логина
class KeysService {
  final Client _client;

  /// Флаг: был ли vodozemac инициализирован глобально
  static bool _vodInitialized = false;

  /// Флаг: vodozemac успешно загрузился (true) или graceful degradation (false)
  static bool get vodozemacReady => _vodInitialized;

  /// Ключ восстановления (сохраняется после initCryptoIdentity)
  static String? _recoveryKey;

  /// Пароль пользователя (для UIA при настройке кросс-подписи)
  static String? _password;

  /// Notifier для ошибок UIA (пароль отсутствует или unsupported stages)
  static final ValueNotifier<String?> onUiaFailed = ValueNotifier<String?>(null);

  KeysService(this._client);

  // ─── Глобальная инициализация vodozemac (до создания Client) ───

  /// Вызывается ОДИН раз перед созданием Client.
  /// На web — загружает WASM из ./pkg/ (требует компиляции vodozemac).
  /// На native — инициализирует нативную библиотеку.
  ///
  /// При ошибке НЕ бросает исключение — E2EE просто будет недоступен
  /// (encryptionEnabled = false), но приложение продолжит работу.
  static Future<void> ensureVodozemacInit() async {
    if (_vodInitialized) return;
    try {
      debugPrint('[E2EE] Initializing vodozemac...');
      await vod.init(wasmPath: './');
      _vodInitialized = true;
      debugPrint('[E2EE] vodozemac initialized successfully');
    } catch (e) {
      debugPrint('[E2EE] vod.init() FAILED: $e');
      // НЕ rethrow — graceful degradation.
      // Если vodozemac не загрузился (нет WASM на web / нет нативной библиотеки),
      // приложение работает без E2EE (encryptionEnabled = false).
      debugPrint('[E2EE] E2EE will be unavailable');
    }
  }

  /// Создать NativeImplementations для Client.constructor.
  /// На web используем dummy (нет изолятов), на native — Isolate.
  static NativeImplementations createNativeImplementations() {
    if (kIsWeb) {
      debugPrint('[E2EE] WEB: using NativeImplementations.dummy');
      return NativeImplementations.dummy;
    }
    debugPrint('[E2EE] NATIVE: using NativeImplementationsIsolate');
    return NativeImplementationsIsolate(
      compute,
      vodozemacInit: () => vod.init(),
    );
  }

  // ─── Управление crypto identity ───

  /// Проверяет состояние crypto identity и при необходимости настраивает.
  ///
  /// Вызывать после логина или восстановления сессии.
  /// Возвращает true если E2EE готово к использованию.
  Future<bool> setupCryptoIdentity() async {
    if (!_client.encryptionEnabled) {
      debugPrint('[E2EE] encryptionEnabled is FALSE — vodozemac may not be initialized');
      return false;
    }

    try {
      final cryptoState = await _client.getCryptoIdentityState();
      debugPrint('[E2EE] Crypto state: initialized=${cryptoState.initialized}, '
          'connected=${cryptoState.connected}');

      if (!cryptoState.initialized) {
        // Проверяем: есть ли кросс-подпись уже на сервере?
        // Если да — это второе устройство, НЕ вызываем initCryptoIdentity
        // (чтобы не затереть существующие ключи)
        final hasMasterKey = _client.userDeviceKeys[_client.userID]?.masterKey != null;
        if (hasMasterKey) {
          debugPrint('[E2EE] Cross-signing master key exists on server -> '
              'this is NOT a first device, falling through to restore');
        } else {
        // Первая настройка — генерируем ключ восстановления
        debugPrint('[E2EE] First-time setup: calling initCryptoIdentity()...');
        debugPrint('[E2EE]   encryption available: ${_client.encryption != null}');
        debugPrint('[E2EE]   keyManager enabled: ${_client.encryption?.keyManager.enabled}');
        debugPrint('[E2EE]   crossSigning enabled: ${_client.encryption?.crossSigning.enabled}');
        // Подписываемся на UIA-запросы для автопрохождения m.login.password
        _handleUiaRequests();
        try {
          debugPrint('[E2EE] ⏳ initCryptoIdentity() started, waiting up to 300s...');
          final recoveryKey = await _client
              .initCryptoIdentity()
              .timeout(const Duration(seconds: 300));
          await persistRecoveryKey(recoveryKey, userId: _client.userID);
          debugPrint('[E2EE] ✅ Crypto identity INITIALIZED');
          debugPrint('[E2EE] 🔑 RECOVERY KEY (save this!): $recoveryKey');
          debugPrint('[E2EE] keyManager enabled: ${_client.encryption?.keyManager.enabled}');
          debugPrint('[E2EE] crossSigning enabled: ${_client.encryption?.crossSigning.enabled}');
          return true;
        } on TimeoutException catch (_) {
          debugPrint('[E2EE] ❌ initCryptoIdentity TIMED OUT after 300s');
          debugPrint('[E2EE] keyManager: ${_client.encryption?.keyManager.enabled}, '
              'crossSigning: ${_client.encryption?.crossSigning.enabled}');
          return false;
        } catch (e, s) {
          debugPrint('[E2EE] ❌ initCryptoIdentity THREW: $e');
          debugPrint('[E2EE] Stack: $s');
          return false;
        } finally {
          disposeUiaHandler();
        }
        } // close else (hasMasterKey == false)
      } // close if (!cryptoState.initialized)

      if (!cryptoState.connected) {
        // Новое устройство или потерянные ключи — пытаемся восстановить
        // Сначала пробуем загрузить ключ из secure storage
        _recoveryKey ??= await loadPersistedRecoveryKey(userId: _client.userID);

        if (_recoveryKey != null) {
          debugPrint('[E2EE] Restoring crypto identity with saved recovery key...');
          try {
            await _client.restoreCryptoIdentity(_recoveryKey!);
            debugPrint('[E2EE] ✅ Crypto identity RESTORED');
            return true;
          } catch (e, s) {
            debugPrint('[E2EE] ❌ restoreCryptoIdentity FAILED: $e');
            debugPrint('[E2EE] Stored key may be stale — clearing it');
            await deleteRecoveryKey(userId: _client.userID);
            _recoveryKey = null;
          }
        }

        // Нет валидного ключа — graceful degradation
        debugPrint('[E2EE] ⚠️ No recovery key available. Device will be untrusted.');
        debugPrint('[E2EE] E2EE works for new messages. Old messages may not decrypt.');
        debugPrint('[E2EE] User should manually enter recovery key or reset encryption.');
        return false;
      }

      // Уже подключены — ничего не делаем
      debugPrint('[E2EE] Crypto identity already connected. E2EE is ready.');
      debugPrint('[E2EE] Identity key: ${_client.identityKey}');
      debugPrint('[E2EE] Fingerprint key: ${_client.fingerprintKey}');
      return true;
    } catch (e) {
      debugPrint('[E2EE] setupCryptoIdentity FAILED: $e');
      return false;
    }
  }

  /// setupCryptoIdentity с автоматическим повтором при ошибке.
  ///
  /// Делает до 3 попыток с exponential backoff (2с, 4с, 8с).
  /// Возвращает true если E2EE готово после всех попыток.
  Future<bool> setupCryptoIdentityWithRetry({int maxAttempts = 3}) async {
    if (!_client.encryptionEnabled) {
      debugPrint('[E2EE] encryptionEnabled is FALSE, skipping retry');
      return false;
    }

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      debugPrint('[E2EE] setupCryptoIdentity attempt $attempt/$maxAttempts...');
      final ok = await setupCryptoIdentity();
      if (ok) {
        debugPrint('[E2EE] setupCryptoIdentity SUCCESS on attempt $attempt');
        // Верифицируем key backup после успешной настройки
        await verifyKeyBackup();
        return true;
      }
      if (attempt < maxAttempts) {
        final delay = Duration(seconds: 2 * (1 << (attempt - 1))); // 2s, 4s, 8s
        debugPrint('[E2EE] setupCryptoIdentity FAILED, retry in ${delay.inSeconds}s...');
        await Future.delayed(delay);
      }
    }
    debugPrint('[E2EE] setupCryptoIdentity FAILED after $maxAttempts attempts');
    return false;
  }

  /// Проверяет, что key backup активен на сервере и локально кеширован.
  /// Логирует диагностику. Не бросает исключений — только предупреждения.
  Future<void> verifyKeyBackup() async {
    if (!_client.encryptionEnabled || _client.encryption == null) return;
    try {
      final km = _client.encryption!.keyManager;
      final kmEnabled = km.enabled;
      final kmCached = await km.isCached();
      debugPrint('[E2EE] Key backup: enabled=$kmEnabled, cached=$kmCached');
      if (kmEnabled && kmCached) {
        debugPrint('[E2EE] Key backup is ACTIVE — server backup ready');
        // Гарантируем, что все inbound sessions загружены в бэкап
        try {
          await km.uploadInboundGroupSessions(skipIfInProgress: true);
        } catch (_) { /* non-critical */ }
      } else if (kmEnabled && !kmCached) {
        debugPrint('[E2EE] ⚠️ Key backup exists on server but key not cached locally. '
            'May need recovery key to restore.');
      } else {
        debugPrint('[E2EE] ⚠️ Key backup NOT enabled on server. '
            'Messages cannot be recovered on other devices without manual key sharing.');
      }
    } catch (e) {
      debugPrint('[E2EE] Key backup verification error: $e');
    }
  }

  // ─── Сброс и пересоздание crypto identity ───

  /// Сбрасывает существующую кросс-подпись и создаёт новую.
  /// Используется когда ключ восстановления утерян,
  /// или когда разные устройства оказались в разных identity.
  ///
  /// Возвращает новый ключ восстановления (recovery key) для отображения пользователю.
  /// Вызывает initCryptoIdentity() с wipeCrossSigning=true, wipeSecureStorage=true.
  Future<String?> resetCryptoIdentity() async {
    if (!_client.encryptionEnabled) {
      debugPrint('[E2EE] encryptionEnabled is FALSE — cannot reset');
      return null;
    }

    try {
      // Подписываемся на UIA-запросы для автопрохождения m.login.password
      _handleUiaRequests();
      debugPrint('[E2EE] ⏳ Resetting crypto identity (wipe + reinit)...');
      final recoveryKey = await _client
          .initCryptoIdentity(
            wipeSecureStorage: true,
            wipeKeyBackup: true,
            wipeCrossSigning: true,
          )
          .timeout(const Duration(seconds: 300));
      await persistRecoveryKey(recoveryKey, userId: _client.userID);
      debugPrint('[E2EE] ✅ Crypto identity RESET');
      debugPrint('[E2EE] 🔑 NEW RECOVERY KEY: $recoveryKey');
      return recoveryKey;
    } on TimeoutException catch (_) {
      debugPrint('[E2EE] ❌ resetCryptoIdentity TIMED OUT');
      return null;
    } catch (e, s) {
      debugPrint('[E2EE] ❌ resetCryptoIdentity FAILED: $e');
      debugPrint('[E2EE] Stack: $s');
      return null;
    } finally {
      disposeUiaHandler();
    }
  }

  // ─── Запрос ключей для зашифрованных комнат ───

  /// Запрос ключей расшифровки для всех зашифрованных комнат.
  /// Вызывается после первого sync, чтобы новое устройство могло расшифровать историю.
  Future<void> requestKeysForEncryptedRooms() async {
    if (!_client.encryptionEnabled) {
      debugPrint('[E2EE] Crypto not enabled, skipping key requests');
      return;
    }

    try {
      final encryptedRooms = _client.rooms.where(
        (room) => room.getState('m.room.encryption') != null,
      );

      int requested = 0;
      for (final room in encryptedRooms) {
        try {
          final lastEvent = room.lastEvent;
          if (lastEvent != null &&
              (lastEvent.type == EventTypes.Encrypted ||
               lastEvent.messageType == MessageTypes.BadEncrypted)) {
            debugPrint('[E2EE] Requesting key for room ${room.id}');
            await lastEvent.requestKey();
            requested++;
          }
        } catch (e) {
          debugPrint('[E2EE] Key request failed for room ${room.id}: $e');
        }
      }
      if (requested > 0) {
        debugPrint('[E2EE] Requested keys for $requested rooms');
      }
    } catch (e) {
      debugPrint('[E2EE] Error requesting keys: $e');
    }
  }

  /// Получить сохранённый ключ восстановления (для отображения пользователю)
  static String? get savedRecoveryKey => _recoveryKey;

  /// Установить ключ восстановления вручную (если пользователь вводит его)
  static void setRecoveryKey(String key) {
    _recoveryKey = key;
  }

  /// Secure storage instance (cross-platform encrypted/plaintext depending on platform)
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    lOptions: LinuxOptions(),
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
    wOptions: WindowsOptions(),
  );

  /// Storage key — scoped per user to prevent cross-account leakage
  static String _storageKey(String? userId) =>
      'private_messenger_recovery_key_${userId ?? 'default'}';

  /// Сохранить ключ восстановления в secure storage (кроссплатформенно)
  static Future<void> persistRecoveryKey(String key, {String? userId}) async {
    _recoveryKey = key;
    try {
      await _secureStorage.write(key: _storageKey(userId), value: key);
      debugPrint('[E2EE] Recovery key saved to secure storage');
    } catch (e) {
      debugPrint('[E2EE] Failed to save recovery key to secure storage: $e');
    }
  }

  /// Загрузить ключ восстановления из secure storage
  static Future<String?> loadPersistedRecoveryKey({String? userId}) async {
    try {
      final val = await _secureStorage.read(key: _storageKey(userId));
      if (val != null) {
        _recoveryKey = val;
        debugPrint('[E2EE] Recovery key loaded from secure storage');
        return val;
      }
    } catch (e) {
      debugPrint('[E2EE] Failed to load recovery key from secure storage: $e');
    }
    return null;
  }

  /// Удалить ключ восстановления из secure storage (при выходе из аккаунта)
  static Future<void> deleteRecoveryKey({String? userId}) async {
    _recoveryKey = null;
    try {
      await _secureStorage.delete(key: _storageKey(userId));
      debugPrint('[E2EE] Recovery key deleted from secure storage');
    } catch (e) {
      debugPrint('[E2EE] Failed to delete recovery key: $e');
    }
  }

  /// Проверить, сохранён ли пароль для UIA
  static bool get hasPassword => _password != null;

  /// Сохранить пароль пользователя для UIA при настройке кросс-подписи
  static void setPassword(String password) {
    _password = password;
  }

  /// Слушатель UIA-запросов для автоподтверждения m.login.password
  StreamSubscription<UiaRequest>? _uiaSubscription;

  /// Подписаться на UIA-запросы и автозаполнять пароль
  void _handleUiaRequests() {
    _uiaSubscription?.cancel();
    _uiaSubscription = _client.onUiaRequest.stream.listen((request) {
      if (request.state != UiaRequestState.waitForUser) return;
      if (_password == null) {
        debugPrint('[E2EE] UIA: password not available, cannot complete auth');
        onUiaFailed.value = 'Для настройки шифрования требуется пароль. '
            'Пожалуйста, введите пароль в настройках E2EE.';
        return;
      }
      if (request.nextStages.contains('m.login.password')) {
        debugPrint('[E2EE] UIA: completing m.login.password');
        onUiaFailed.value = null; // Ошибка исправлена
        request.completeStage(
          AuthenticationData(
            type: 'm.login.password',
            session: request.session,
            additionalFields: {
              'identifier': {
                'type': 'm.id.user',
                'user': _client.userID,
              },
              'password': _password,
            },
          ),
        );
      } else {
        debugPrint('[E2EE] UIA: unsupported stages: ${request.nextStages}');
        onUiaFailed.value = 'Сервер запросил неподдерживаемый метод авторизации: '
            '${request.nextStages.join(', ')}. Настройка E2EE не удалась.';
      }
    });
  }

  /// Отписаться от UIA-запросов
  void disposeUiaHandler() {
    _uiaSubscription?.cancel();
    _uiaSubscription = null;
  }
}
