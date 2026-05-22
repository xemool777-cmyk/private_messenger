// Web implementation of notification service using browser Notification API
// Works on: Chrome/Firefox/Edge desktop, Android Chrome, iOS Safari 16.4+ (PWA only)
// Uses dart:js_interop + package:web (replaces deprecated dart:html + dart:js)

import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// JS interop для Notification API
@JS('Notification')
extension type JSNotification._(JSObject _) implements JSObject {
  external static String get permission;
  external static JSPromise requestPermission();
  external JSNotification(String title, JSNotificationOptions options);
  external set onclick(JSFunction handler);
  external void close();
}

/// Notification options (anonymous JS object literal)
@JS()
extension type JSNotificationOptions._(JSObject _) implements JSObject {
  external JSNotificationOptions({String? body, String? tag});
}

Future<void> initNativeNotifications(StreamController<String> payloadController) async {
  try {
    if (!_notificationSupported()) {
      debugPrint('[NOTIFY] Web: Notification API not supported');
      return;
    }
    final perm = JSNotification.permission;
    debugPrint('[NOTIFY] Web: Current permission = $perm');
    if (perm == 'granted') return;
    if (perm != 'denied') {
      try {
        await JSNotification.requestPermission().toDart;
        debugPrint('[NOTIFY] Web: Permission after request = ${JSNotification.permission}');
      } catch (e) {
        debugPrint('[NOTIFY] Web: requestPermission error: $e');
      }
    }
  } catch (e) {
    debugPrint('[NOTIFY] Web: init error: $e');
  }
}

Future<void> showNativeNotification({
  required String roomId,
  required String roomName,
  required String senderName,
  required String messageText,
}) async {
  try {
    if (!_notificationSupported()) return;
    if (JSNotification.permission != 'granted') return;

    final title = '$senderName в $roomName';
    final options = JSNotificationOptions(body: messageText);
    final notification = JSNotification(title, options);

    notification.onclick = (() {
      web.window.focus();
      notification.close();
    }).toJS;

    debugPrint('[NOTIFY] Web: Shown notification: $title');
  } catch (e) {
    debugPrint('[NOTIFY] Web: Error showing notification: $e');
  }
}

Future<void> cancelNativeNotification(String roomId) async {}

Future<void> cancelAllNativeNotifications() async {}

/// Проверяет поддержку Notification API
bool _notificationSupported() {
  try {
    // Пробуем обратиться к статическому свойству — если Notification нет, будет ошибка
    JSNotification.permission;
    return true;
  } catch (_) {
    return false;
  }
}
