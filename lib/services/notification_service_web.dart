// Web реализация сервиса уведомлений через Browser Notification API
// Поддерживает: Chrome, Firefox, Edge, Safari 16.4+
// Требует HTTPS для работы (или localhost для разработки)

import 'dart:async';
import 'dart:js_interop';

/// Результат запроса разрешения на уведомления
enum WebNotificationPermission {
  granted,   // Разрешено
  denied,    // Запрещено
  default_,  // Не запрошено
}

/// Инициализация уведомлений на веб
/// Запрашивает разрешение если ещё не запрошено
Future<void> initNativeNotifications(StreamController<String> payloadController) async {
  try {
    final permission = _getNotificationPermission();
    if (permission == WebNotificationPermission.default_) {
      // Запрашиваем разрешение
      final result = await _requestPermission();
      if (result == 'granted') {
        print('[NOTIFY-WEB] Notification permission granted');
      } else {
        print('[NOTIFY-WEB] Notification permission denied');
      }
    } else if (permission == WebNotificationPermission.granted) {
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
    if (permission != WebNotificationPermission.granted) return;

    // Создаём уведомление через Notification API
    _showBrowserNotification(
      title: '$senderName в $roomName',
      body: messageText,
      tag: roomId, // tag группирует уведомления по комнате
    );
  } catch (e) {
    print('[NOTIFY-WEB] Show notification error: $e');
  }
}

/// Скрыть уведомление для комнаты
Future<void> cancelNativeNotification(String roomId) async {
  // Browser Notification API не поддерживает прямое закрытие по tag
  // Уведомления закроются автоматически при открытии приложения
}

/// Скрыть все уведомления
Future<void> cancelAllNativeNotifications() async {
  // Аналогично — закроются автоматически
}

// ============================================
// JS Interop helpers
// ============================================

WebNotificationPermission _getNotificationPermission() {
  try {
    final perm = _jsGetNotificationPermission();
    switch (perm) {
      case 'granted':
        return WebNotificationPermission.granted;
      case 'denied':
        return WebNotificationPermission.denied;
      default:
        return WebNotificationPermission.default_;
    }
  } catch (_) {
    return WebNotificationPermission.denied;
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
  _jsShowNotification(title, body, tag);
}

// ============================================
// Low-level JS interop
// ============================================

@JS('Notification.permission')
external String _jsGetNotificationPermission();

@JS('Notification.requestPermission')
external JSPromise<JSString> _jsRequestNotificationPermissionJS();

Future<String> _jsRequestNotificationPermission() async {
  final result = await _jsRequestNotificationPermissionJS().toDart;
  return result.toDart;
}

@JS()
@staticInterop
class JSNotification {}

@JS('new Notification')
external JSNotification _jsNewNotification(
  String title,
  JSObject options,
);

void _jsShowNotification(String title, String body, String tag) {
  try {
    // Создаём options объект
    final options = _jsCreateNotificationOptions(body, tag);
    _jsNewNotification(title, options);
  } catch (e) {
    print('[NOTIFY-WEB] JS Notification error: $e');
  }
}

@JS()
@staticInterop
class JSNotificationOptions {}

@JS()
external JSNotificationOptions _jsCreateNotificationOptions(String body, String tag);
