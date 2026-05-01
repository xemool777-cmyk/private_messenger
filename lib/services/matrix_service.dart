import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:olm/olm.dart' as olm;
import 'notification_service.dart';

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

  /// Текущая открытая комната (чтобы не показывать уведомление для неё)
  String? _currentRoomId;
  String? get currentRoomId => _currentRoomId;
  set currentRoomId(String? id) => _currentRoomId = id;

  /// Инициализация: Matrix клиент с Hive базой данных
  Future<void> init() async {
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

    // Дополнительная диагностика E2EE на веб
    if (kIsWeb && !_client.encryptionEnabled) {
      debugPrint('[Matrix] WEB: E2EE is NOT working. olm.js may not be loaded correctly.');
      debugPrint('[Matrix] WEB: Check that web/olm.js exists and is loaded in index.html');
      // Пробуем инициализировать Olm вручную чтобы увидеть ошибку
      try {
        await olm.init();
        debugPrint('[Matrix] WEB: olm.init() succeeded manually! But Client.init() failed to use it.');
      } catch (e2) {
        debugPrint('[Matrix] WEB: olm.init() failed: $e2');
      }
    }

    if (_client.encryptionEnabled) {
      debugPrint('[Matrix] Identity key: ${_client.identityKey}');
      debugPrint('[Matrix] Fingerprint key: ${_client.fingerprintKey}');
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
    _syncSub = _client.onSync.stream.listen((syncUpdate) {
      final joinedRooms = syncUpdate.rooms?.join;
      if (joinedRooms == null || joinedRooms.isEmpty) return;

      for (final entry in joinedRooms.entries) {
        final roomId = entry.key;
        final roomData = entry.value;

        // Получаем новые события из timeline
        final timelineEvents = roomData.timeline?.events;
        if (timelineEvents == null || timelineEvents.isEmpty) continue;

        for (final matrixEvent in timelineEvents) {
          final eventType = matrixEvent.type;
          final senderId = matrixEvent.senderId;

          // Пропускаем свои же сообщения
          if (senderId == _client.userID) continue;

          // Обычные сообщения и зашифрованные сообщения
          // В зашифрованных комнатах сообщения приходят как m.room.encrypted
          if (eventType != 'm.room.message' && eventType != 'm.room.encrypted') continue;

          // Не показываем уведомление если мы сейчас в этом чате
          if (_currentRoomId == roomId) continue;

          // Получаем комнату
          final room = _client.getRoomById(roomId);
          if (room == null) continue;

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
            // Зашифрованное сообщение — показываем общее уведомление
            // Расшифровка произойдёт позже когда SDK обработает событие
            messageText = '🔐 Зашифрованное сообщение';
            debugPrint('[NOTIFY] Encrypted message in $roomId from $senderName');
          } else {
            // Обычное сообщение — извлекаем текст
            final content = matrixEvent.content;
            final msgtype = content['msgtype'] as String? ?? '';
            final body = content['body'] as String? ?? '';

            if (msgtype == 'm.image') {
              messageText = '📷 Фото';
            } else if (msgtype == 'm.file') {
              messageText = '📎 Файл';
            } else if (msgtype == 'm.audio') {
              messageText = '🎵 Аудио';
            } else if (msgtype == 'm.video') {
              messageText = '🎬 Видео';
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
