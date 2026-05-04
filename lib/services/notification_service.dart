import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'notification_service_native.dart' if (dart.library.js_interop) 'notification_service_web.dart';

/// Сервис локальных уведомлений
/// Показывает уведомления о новых сообщениях когда приложение в фоне
/// Web: Browser Notification API, Native: flutter_local_notifications
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  static NotificationService get instance => _instance;
  NotificationService._();

  bool _initialized = false;

  // Стрим для передачи payload нажатого уведомления
  final _notificationPayloadController = StreamController<String>.broadcast();
  Stream<String> get onNotificationTapped => _notificationPayloadController.stream;

  /// Инициализация плагина уведомлений
  Future<void> init() async {
    if (_initialized) return;
    // На всех платформах — инициализируем через делегат
    // Web: Browser Notification API (через notification_service_web.dart)
    // Native: flutter_local_notifications
    await initNativeNotifications(_notificationPayloadController);
    _initialized = true;
  }

  /// Показать уведомление о новом сообщении
  Future<void> showMessageNotification({
    required String roomId,
    required String roomName,
    required String senderName,
    required String messageText,
  }) async {
    if (!_initialized) await init();
    await showNativeNotification(
      roomId: roomId,
      roomName: roomName,
      senderName: senderName,
      messageText: messageText,
    );
  }

  /// Скрыть уведомление для конкретной комнаты
  Future<void> cancelNotification(String roomId) async {
    await cancelNativeNotification(roomId);
  }

  /// Скрыть все уведомления
  Future<void> cancelAllNotifications() async {
    await cancelAllNativeNotifications();
  }

  void dispose() {
    _notificationPayloadController.close();
  }
}

/// Глобальный ключ навигатора для переходов из уведомлений
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
