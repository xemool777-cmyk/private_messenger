// Web реализация сервиса уведомлений через Browser Notification API
// Поддерживает: Chrome, Firefox, Edge, Safari 16.4+
// Требует HTTPS для работы (или localhost для разработки)

import 'dart:async';
import 'dart:js_interop';

/// Инициализация уведомлений на веб
/// Запрашивает разрешение если ещё не запрошено
Future<void> initNativeNotifications(StreamController<String> payloadController) async {
  try {
    final permission = _getNotificationPermission();
    if (permission == 'default') {
      final result = await _requestPermission();
      if (result == 'granted') {
        print('[NOTIFY-WEB] Notification permission granted');
      } else {
        print('[NOTIFY-WEB] Notification permission denied');
      }
    } else if (permission == 'granted') {
      print('[NOTIFY-WEB] Notifications already permitted');
    } else {
      print('[NOTIFY-WEB] Notifications blocked by user');
    }
  } catch (e) {
    print('[NOTIFY-WEB] Init error: $e');
  }
}

/// Показать уведомление в браузере
Future<void> showNativeNotification({
  required String roomId,
  required String roomName,
  required String senderName,
  required String messageText,
}) async {
  try {
    final permission = _getNotificationPermission();
    if (permission != 'granted') return;

    _showBrowserNotification(
      title: '$senderName в $roomName',
      body: messageText,
      tag: roomId,
    );
  } catch (e) {
    print('[NOTIFY-WEB] Show notification error: $e');
  }
}

/// Скрыть уведомление для комнаты
Future<void> cancelNativeNotification(String roomId) async {
  // Browser Notification API не поддерживает прямое закрытие по tag
}

/// Скрыть все уведомления
Future<void> cancelAllNativeNotifications() async {
  // Аналогично — закроются автоматически
}

// ============================================
// JS Interop — используем js_interop для wasm-компиляции
// ============================================

String _getNotificationPermission() {
  try {
    return _jsGetNotificationPermission().toDart;
  } catch (_) {
    return 'denied';
  }
}

Future<String> _requestPermission() async {
  try {
    final result = await _jsRequestNotificationPermission();
    return result;
  } catch (_) {
    return 'denied';
  }
}

void _showBrowserNotification({
  required String title,
  required String body,
  required String tag,
}) {
  try {
    _jsShowNotification(title.toJS, body.toJS, tag.toJS);
  } catch (e) {
    print('[NOTIFY-WEB] JS Notification error: $e');
  }
}

// ============================================
// Low-level JS interop bindings
// ============================================

@JS('Notification.permission')
external JSString _jsGetNotificationPermission();

@JS('Notification.requestPermission')
external JSPromise<JSString> _jsRequestNotificationPermissionJS();

Future<String> _jsRequestNotificationPermission() async {
  final result = await _jsRequestNotificationPermissionJS().toDart;
  return result.toDart;
}

/// Создаёт уведомление через new Notification(title, options)
@JS('Notification')
external void _jsShowNotification(JSString title, JSString body, JSString tag);
