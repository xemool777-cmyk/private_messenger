// Web stub implementation of notification service
// This file is only imported on web platforms
// flutter_local_notifications does NOT support web, so all methods are no-ops

import 'dart:async';

/// Stub — на веб уведомления не поддерживаются
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
