import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:olm/olm.dart' as olm;
import 'notification_service.dart';

/// Глобальный флаг: был ли olm инициализирован вручную на веб
bool _olmPreInitialized = false;

/// Сервис управления Matrix клиентом
/// Отвечает за инициализацию, логин, регистрацию, синхронизацию, уведомления
class MatrixService {
  static const String homeserverUrl = 'https://xemooll.ru';
  static const String serverName = 'xemooll.ru';

  late final Client _client;
  Client get client => _client;

  /// Кэшированный userId (client.userID может быть null после восстановления сессии)
  String? _cachedUserId;
  String get userId => _cachedUserId ?? _client.userID ?? '';

  StreamSubscription? _syncSub;
  bool _firstSyncDone = false;

  /// Текущая открытая комната (чтобы не показывать уведомление для неё)
  String? _currentRoomId;
  String? get currentRoomId => _currentRoomId;
  set currentRoomId(String? id) => _currentRoomId = id;

  /// Инициализация: Matrix клиент с Hive базой данных
  Future<void> init() async {
    // На веб ПРЕДЗАГРУЖАЕМ olm WASM-модуль ДО создания клиента
    // Это критично: Client.init() внутри login() может не дождаться загрузки WASM
    if (kIsWeb && !_olmPreInitialized) {
      try {
        debugPrint('[Matrix] WEB: Pre-initializing olm WASM module...');
        await olm.init();
        final version = olm.get_library_version();
        debugPrint('[Matrix] WEB: olm pre-init OK, version: $version');
        _olmPreInitialized = true;
      } catch (e) {
        debugPrint('[Matrix] WEB: olm pre-init FAILED: $e');
        debugPrint('[Matrix] WEB: E2EE will NOT work. Check that web/olm.js and web/olm.wasm exist.');
      }
    }

    // На веб используем IndexedDB (путь не нужен), на нативных — файловая система
    _client = Client(
      'PrivateMessenger',
      databaseBuilder: (_) async {
        if (kIsWeb) {
          // На веб Hive автоматически использует IndexedDB
          final db = HiveCollectionsDatabase('private_messenger_db', 'private_messenger_db');
          await db.open();
          return db;
        } else {
          final dir = await getApplicationSupportDirectory();
          final db = HiveCollectionsDatabase('private_messenger_db', dir.path);
          await db.open();
          return db;
        }
      },
    );

    // Инициализация клиента — запускает синхронизацию если уже залогинен
    try {
      await _client.init();
    } catch (e) {
      debugPrint('[Matrix] Client.init() error: $e');
    }
    _cachedUserId = _client.userID;
    debugPrint('[Matrix] After init: userID = $_cachedUserId');
    debugPrint('[Matrix] Encryption enabled: ${_client.encryptionEnabled}');
    debugPrint('[Matrix] Encryption object: ${_client.encryption != null ? "present" : "NULL"}');

    // E2EE диагностика
    if (_client.encryptionEnabled) {
      debugPrint('[Matrix] Identity key: ${_client.identityKey}');
      debugPrint('[Matrix] Fingerprint key: ${_client.fingerprintKey}');
    } else if (kIsWeb) {
      debugPrint('[Matrix] WEB: E2EE not yet enabled (expected before login). olm pre-init: $_olmPreInitialized');
    }

    // Если уже залогинен — подключаемся к homeserver чтобы API работал
    if (_client.isLogged()) {
      try {
        await _client.checkHomeserver(Uri.parse(homeserverUrl));
        debugPrint('[Matrix] Homeserver reconnected for existing session');
      } catch (e) {
        debugPrint('[Matrix] Failed to reconnect homeserver: $e');
      }
    }

    // Инициализируем сервис уведомлений
    await NotificationService.instance.init();

    // Слушаем входящие сообщения для уведомлений
    _startListeningForNotifications();
  }

  /// Слушаем синхронизацию и показываем уведомления о новых сообщениях
  void _startListeningForNotifications() {
    // Множество уже обработанных событий (чтобы не дублировать уведомления)
    final processedEventIds = <String>{};

    _syncSub = _client.onSync.stream.listen((syncUpdate) {
      final joinedRooms = syncUpdate.rooms?.join;
      if (joinedRooms == null || joinedRooms.isEmpty) return;

      // После первого sync — запрашиваем ключи для зашифрованных комнат
      // Это критично для новых устройств, у которых нет ключей Megolm
      if (!_firstSyncDone && _client.encryptionEnabled) {
        _firstSyncDone = true;
        _requestKeysForEncryptedRooms();
      }

      for (final entry in joinedRooms.entries) {
        final roomId = entry.key;
        final roomData = entry.value;

        // Получаем новые события из timeline
        final timelineEvents = roomData.timeline?.events;
        if (timelineEvents == null || timelineEvents.isEmpty) continue;

        for (final matrixEvent in timelineEvents) {
          final eventType = matrixEvent.type;
          final senderId = matrixEvent.senderId;
          final eventId = matrixEvent.eventId;

          // Пропускаем дубликаты
          if (eventId != null && processedEventIds.contains(eventId)) continue;
          if (eventId != null) processedEventIds.add(eventId);

          // Очищаем старые ID (держим максимум 200)
          if (processedEventIds.length > 200) {
            processedEventIds.remove(processedEventIds.first);
          }

          // Пропускаем свои же сообщения
          if (senderId == _client.userID) continue;

          // Обычные сообщения и зашифрованные сообщения
          if (eventType != 'm.room.message' && eventType != 'm.room.encrypted') continue;

          // Не показываем уведомление если мы сейчас в этом чате
          if (_currentRoomId == roomId) continue;

          // Получаем комнату
          final room = _client.getRoomById(roomId);
          if (room == null) continue;

          // Проверяем — зашифрованная ли комната
          final isEncryptedRoom = room.getState('m.room.encryption') != null;

          // Имя отправителя — из участников комнаты
          String senderName = senderId?.localpart ?? 'Неизвестный';
          try {
            final memberEvent = room.getState('m.room.member', senderId);
            if (memberEvent != null) {
              final displayName = memberEvent.content['displayname'] as String?;
              if (displayName != null && displayName.isNotEmpty) {
                senderName = displayName;
              }
            }
          } catch (_) {}

          String messageText;

          if (eventType == 'm.room.encrypted') {
            // Сырое зашифрованное событие из sync — показываем общее уведомление
            messageText = 'Новое зашифрованное сообщение';
            debugPrint('[NOTIFY] Encrypted event in $roomId from $senderName');
          } else if (isEncryptedRoom && eventType == 'm.room.message') {
            // SDK расшифровал событие и заменил тип на m.room.message
            // Пытаемся получить текст из контента
            final content = matrixEvent.content;
            final msgtype = content['msgtype'] as String? ?? '';
            final body = content['body'] as String? ?? '';

            if (msgtype == 'm.image') {
              messageText = 'Фото';
            } else if (msgtype == 'm.file') {
              messageText = 'Файл';
            } else if (msgtype == 'm.audio') {
              messageText = 'Аудио';
            } else if (msgtype == 'm.video') {
              messageText = 'Видео';
            } else {
              messageText = body.isNotEmpty ? body : 'Новое сообщение';
            }
            debugPrint('[NOTIFY] Decrypted message in $roomId from $senderName: $messageText');
          } else {
            // Обычное (не зашифрованное) сообщение
            final content = matrixEvent.content;
            final msgtype = content['msgtype'] as String? ?? '';
            final body = content['body'] as String? ?? '';

            if (msgtype == 'm.image') {
              messageText = 'Фото';
            } else if (msgtype == 'm.file') {
              messageText = 'Файл';
            } else if (msgtype == 'm.audio') {
              messageText = 'Аудио';
            } else if (msgtype == 'm.video') {
              messageText = 'Видео';
            } else {
              messageText = body.isNotEmpty ? body : 'Новое сообщение';
            }
            debugPrint('[NOTIFY] New message in $roomId from $senderName: $messageText');
          }

          // Показываем уведомление
          NotificationService.instance.showMessageNotification(
            roomId: roomId,
            roomName: room.displayname,
            senderName: senderName,
            messageText: messageText,
          );
        }
      }
    });
  }

  /// Запрос ключей расшифровки для всех зашифрованных комнат
  /// Вызывается после первого sync, чтобы новое устройство могло расшифровать историю
  Future<void> _requestKeysForEncryptedRooms() async {
    if (!_client.encryptionEnabled) return;

    try {
      final encryptedRooms = _client.rooms.where(
        (room) => room.getState('m.room.encryption') != null,
      );

      for (final room in encryptedRooms) {
        try {
          // Проверяем последнее событие — если не расшифровано, запрашиваем ключ
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

  /// Проверка — пользователь уже залогинен?
  bool get isLogged => _client.isLogged();

  /// Подключение к homeserver
  Future<void> connectToHomeserver() async {
    await _client.checkHomeserver(Uri.parse(homeserverUrl));
  }

  /// Логин пользователя
  /// После login() синхронизация запускается автоматически
  Future<void> login(String username, String password) async {
    // Если уже залогинен — не логинимся повторно
    if (_client.isLogged()) {
      debugPrint('[Matrix] Already logged in, skipping login');
      _cachedUserId = _client.userID;
      return;
    }

    await connectToHomeserver();

    try {
      await _client.login(
        LoginType.mLoginPassword,
        password: password,
        identifier: AuthenticationUserIdentifier(user: username),
      );
    } on MatrixException catch (e) {
      if (e.errcode == 'M_FORBIDDEN' || e.errcode == 'M_USER_IN_USE') {
        // Автоматическая регистрация если логин не удался
        await _client.register(
          username: username,
          password: password,
          auth: AuthenticationData.fromJson({'type': 'm.login.dummy'}),
        );
      } else {
        rethrow;
      }
    }
    _cachedUserId = _client.userID;
    debugPrint('[Matrix] After login: userID = $_cachedUserId');

    // КРИТИЧЕСКАЯ ПРОВЕРКА: работает ли E2EE после логина
    debugPrint('[Matrix] After login: encryptionEnabled = ${_client.encryptionEnabled}');
    debugPrint('[Matrix] After login: encryption = ${_client.encryption != null ? "present" : "NULL"}');
    if (_client.encryptionEnabled) {
      debugPrint('[Matrix] E2EE WORKING! Identity key: ${_client.identityKey}');
      debugPrint('[Matrix] E2EE WORKING! Fingerprint key: ${_client.fingerprintKey}');
    } else {
      debugPrint('[Matrix] WARNING: E2EE is NOT enabled after login!');
      if (kIsWeb) {
        debugPrint('[Matrix] WEB: E2EE failed. olm was pre-initialized: $_olmPreInitialized');
        debugPrint('[Matrix] WEB: This means Client.init() inside login() failed to set up encryption.');
        debugPrint('[Matrix] WEB: Possible causes:');
        debugPrint('[Matrix] WEB:   1. olm.wasm not found or CORS blocked');
        debugPrint('[Matrix] WEB:   2. uploadKeys() failed (network/CORS)');
        debugPrint('[Matrix] WEB:   3. Browser too old for WASM');
      } else {
        debugPrint('[Matrix] NATIVE: E2EE failed! flutter_olm may not be linked correctly.');
      }
    }
    // Синхронизация запускается автоматически через init() внутри login()
  }

  /// Восстановление сессии (если уже залогинен при запуске)
  /// init() уже вызван в init(), поэтому сессия восстанавливается автоматически
  Future<void> resumeSession() async {
    if (_client.isLogged()) {
      if (_client.homeserver == null) {
        await connectToHomeserver();
      }
      // Один ручной sync чтобы обновить данные
      await _client.oneShotSync();

      // Проверяем E2EE при восстановлении сессии
      debugPrint('[Matrix] Session restored: encryptionEnabled = ${_client.encryptionEnabled}');
      if (_client.encryptionEnabled) {
        debugPrint('[Matrix] E2EE OK after session restore. Identity: ${_client.identityKey}');
      } else {
        debugPrint('[Matrix] WARNING: E2EE not enabled after session restore!');
      }
    }
  }

  /// Выход из аккаунта
  Future<void> logout() async {
    await _client.logout();
    await NotificationService.instance.cancelAllNotifications();
  }

  /// Формирование полного Matrix ID
  static String buildUserId(String username) {
    return '@$username:$serverName';
  }

  void dispose() {
    _syncSub?.cancel();
    NotificationService.instance.dispose();
  }
}
