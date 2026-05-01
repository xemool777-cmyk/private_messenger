import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_olm/flutter_olm.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
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
    // Инициализируем libolm для E2EE шифрования
    try {
      await Olm.init();
      debugPrint('[Matrix] Olm initialized successfully');
    } catch (e) {
      debugPrint('[Matrix] Olm init failed (E2EE will not work): $e');
    }

    _client = Client(
      'PrivateMessenger',
      databaseBuilder: (_) async {
        final dir = await getApplicationSupportDirectory();
        final db = HiveCollectionsDatabase('private_messenger_db', dir.path);
        await db.open();
        return db;
      },
    );

    // Инициализация клиента — запускает синхронизацию если уже залогинен
    await _client.init();
    _cachedUserId = _client.userID;
    debugPrint('[Matrix] After init: userID = $_cachedUserId');

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
          // MatrixEvent имеет свойства type, senderId, content
          final eventType = matrixEvent.type;
          final senderId = matrixEvent.senderId;

          // Пропускаем свои же сообщения
          if (senderId == _client.userID) continue;

          // Только сообщения
          if (eventType != 'm.room.message') continue;

          // Не показываем уведомление если мы сейчас в этом чате
          if (_currentRoomId == roomId) continue;

          // Получаем комнату
          final room = _client.getRoomById(roomId);
          if (room == null) continue;

          // Извлекаем текст сообщения из content
          final content = matrixEvent.content;
          final msgtype = content['msgtype'] as String? ?? '';
          final body = content['body'] as String? ?? '';

          String messageText;
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

          // Имя отправителя — из участников комнаты
          String senderName = senderId?.localpart ?? 'Неизвестный';
          try {
            // Пробуем получить displayname из состояния комнаты
            final memberEvent = room.getState('m.room.member', senderId);
            if (memberEvent != null) {
              final displayName = memberEvent.content['displayname'] as String?;
              if (displayName != null && displayName.isNotEmpty) {
                senderName = displayName;
              }
            }
          } catch (_) {}

          debugPrint('[NOTIFY] New message in $roomId from $senderName: $messageText');

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
