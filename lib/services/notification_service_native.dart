// Native implementation of notification service (Android/iOS)
// This file is only imported on native platforms (NOT web)

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Инициализация нативных уведомлений
Future<void> initNativeNotifications(StreamController<String> payloadController) async {
  final plugin = FlutterLocalNotificationsPlugin();

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

  await plugin.initialize(
    settings,
    onDidReceiveNotificationResponse: (response) {
      final payload = response.payload;
      if (payload != null && payload.isNotEmpty) {
        payloadController.add(payload);
      }
    },
  );

  // Создаём канал уведомлений для Android
  if (Platform.isAndroid) {
    final androidPlugin = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.createNotificationChannel(const AndroidNotificationChannel(
        'messages',
        'Сообщения',
        description: 'Уведомления о новых сообщениях',
        importance: Importance.high,
      ));
      await androidPlugin.requestNotificationsPermission();
    }
  }

  debugPrint('[NOTIFY] NotificationService initialized');
}

/// Показать нативное уведомление
Future<void> showNativeNotification({
  required String roomId,
  required String roomName,
  required String senderName,
  required String messageText,
}) async {
  final plugin = FlutterLocalNotificationsPlugin();

  final androidDetails = AndroidNotificationDetails(
    'messages',
    'Сообщения',
    channelDescription: 'Уведомления о новых сообщениях',
    importance: Importance.high,
    priority: Priority.high,
    showWhen: true,
    groupKey: 'room_$roomId',
  );

  const iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  );

  final details = NotificationDetails(
    android: androidDetails,
    iOS: iosDetails,
  );

  final notificationId = roomId.hashCode % 100000;

  try {
    await plugin.show(
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

/// Скрыть уведомление
Future<void> cancelNativeNotification(String roomId) async {
  final plugin = FlutterLocalNotificationsPlugin();
  final notificationId = roomId.hashCode % 100000;
  await plugin.cancel(notificationId);
}

/// Скрыть все уведомления
Future<void> cancelAllNativeNotifications() async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.cancelAll();
}
