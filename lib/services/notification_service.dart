import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Сервис локальных уведомлений
/// Показывает уведомления о новых сообщениях когда приложение в фоне
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  static NotificationService get instance => _instance;
  NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Инициализация плагина уведомлений
  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Создаём канал уведомлений для Android
    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        await androidPlugin.createNotificationChannel(const AndroidNotificationChannel(
          'messages',
          'Сообщения',
          description: 'Уведомления о новых сообщениях',
          importance: Importance.high,
        ));
        // Запрашиваем разрешение на уведомления (Android 13+)
        await androidPlugin.requestNotificationsPermission();
      }
    }

    _initialized = true;
    debugPrint('[NOTIFY] NotificationService initialized');
  }

  /// Обработка нажатия на уведомление
  void _onNotificationTapped(NotificationResponse response) {
    debugPrint('[NOTIFY] Notification tapped: ${response.payload}');
    // Навигация обрабатывается через глобальный ключ навигатора
    final payload = response.payload;
    if (payload != null && payload.isNotEmpty) {
      _notificationPayloadController.add(payload);
    }
  }

  // Стрим для передачи payload нажатого уведомления
  final _notificationPayloadController = StreamController<String>.broadcast();
  Stream<String> get onNotificationTapped => _notificationPayloadController.stream;

  /// Показать уведомление о новом сообщении
  Future<void> showMessageNotification({
    required String roomId,
    required String roomName,
    required String senderName,
    required String messageText,
  }) async {
    if (!_initialized) await init();

    const androidDetails = AndroidNotificationDetails(
      'messages',
      'Сообщения',
      channelDescription: 'Уведомления о новых сообщениях',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      // Группируем уведомления по комнате
      groupKey: 'room_$roomId',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Уникальный ID для каждого уведомления (на основе hashCode roomId)
    final notificationId = roomId.hashCode % 100000;

    try {
      await _plugin.show(
        notificationId,
        roomName,
        '$senderName: $messageText',
        details,
        payload: roomId,
      );
      debugPrint('[NOTIFY] Shown notification: $roomName from $senderName');
    } catch (e) {
      debugPrint('[NOTIFY] Error showing notification: $e');
    }
  }

  /// Скрыть уведомление для конкретной комнаты
  Future<void> cancelNotification(String roomId) async {
    final notificationId = roomId.hashCode % 100000;
    await _plugin.cancel(notificationId);
  }

  /// Скрыть все уведомления
  Future<void> cancelAllNotifications() async {
    await _plugin.cancelAll();
  }

  void dispose() {
    _notificationPayloadController.close();
  }
}

/// Глобальный ключ навигатора для переходов из уведомлений
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
