// Web stub реализация сервиса уведомлений
// ИСПОЛЬЗУЕТСЯ когда dart:js_interop НЕ доступен (старые Flutter версий)
// Если ваш Flutter поддерживает dart:js_interop (3.3+) — используйте notification_service_web.dart

import 'dart:async';

/// Stub — на веб уведомления не поддерживаются (fallback)
Future<void> initNativeNotifications(StreamController<String> payloadController) async {}

/// Stub — на веб уведомления не поддерживаются
Future<void> showNativeNotification({
  required String roomId,
  required String roomName,
  required String senderName,
  required String messageText,
}) async {}

/// Stub — на веб уведомления не поддерживаются
Future<void> cancelNativeNotification(String roomId) async {}

/// Stub — на веб уведомления не поддерживаются
Future<void> cancelAllNativeNotifications() async {}
