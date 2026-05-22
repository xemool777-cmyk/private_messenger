import 'dart:async';
import 'package:flutter/material.dart';
import 'notification_service_web.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._();
  static NotificationService get instance => _instance;
  NotificationService._();

  bool _initialized = false;

  final _notificationPayloadController = StreamController<String>.broadcast();
  Stream<String> get onNotificationTapped => _notificationPayloadController.stream;

  Future<void> init() async {
    if (_initialized) return;
    await initNativeNotifications(_notificationPayloadController);
    _initialized = true;
  }

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

  Future<void> cancelNotification(String roomId) async {
    await cancelNativeNotification(roomId);
  }

  Future<void> cancelAllNotifications() async {
    await cancelAllNativeNotifications();
  }

  void dispose() {
    _notificationPayloadController.close();
  }
}

/// Глобальный ключ навигатора для переходов из уведомлений
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
