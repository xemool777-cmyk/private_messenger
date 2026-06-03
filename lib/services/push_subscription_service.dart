import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:web/web.dart' as web;

/// Dart-обёртка над JS функциями из push_helper.js
@JS('registerPush')
external JSPromise<JSAny?> _registerPushJS();

@JS('sendSubscriptionToGateway')
external JSPromise<JSBoolean> _sendSubscriptionToGatewayJS(JSObject subscription);

@JS('unregisterPush')
external JSPromise<JSAny?> _unregisterPushJS();

/// Сервис для регистрации PushSubscription (Web Push API + Matrix Pusher).
///
/// Жизненный цикл:
/// 1. Вызвать [registerAndSetupPusher] после логина пользователя
/// 2. Сервис регистрирует PushSubscription через Service Worker
/// 3. Отправляет подписку в push gateway
/// 4. Регистрирует pusher на Conduit через Matrix API (postPusher)
class PushSubscriptionService {
  static final PushSubscriptionService _instance =
      PushSubscriptionService._();
  static PushSubscriptionService get instance => _instance;
  PushSubscriptionService._();

  static const String _pushGatewayUrl = 'https://app.xemooll.ru/gw';
  bool _initialized = false;

  /// Основной метод: регистрирует push и настраивает pusher на Conduit.
  /// Вызывать после успешного логина пользователя.
  Future<void> registerAndSetupPusher(Client client) async {
    if (_initialized) {
      debugPrint('[PUSH] Already initialized, skipping');
      return;
    }

    // 1. Регистрируем PushSubscription через Service Worker
    debugPrint('[PUSH] Starting push subscription registration...');
    final subscriptionJson = await _registerPush();
    if (subscriptionJson == null) {
      debugPrint('[PUSH] Push subscription failed — not supported or denied');
      return;
    }

    // 2. Отправляем подписку в push gateway
    final pushkey = subscriptionJson['endpoint'] as String? ?? '';
    if (pushkey.isEmpty) {
      debugPrint('[PUSH] No pushkey in subscription');
      return;
    }
    await _sendToGateway(subscriptionJson);

    // 3. Регистрируем pusher на Conduit
    await _registerPusherOnConduit(client, pushkey);

    _initialized = true;
    debugPrint('[PUSH] Push subscription fully set up');
  }

  /// Удаляет push подписку при логауте
  Future<void> unregister() async {
    try {
      await _unregisterPushJS().toDart;
    } catch (e) {
      debugPrint('[PUSH] Unregister error: $e');
    }
    _initialized = false;
    debugPrint('[PUSH] Unregistered');
  }

  // ─── Приватные методы ───

  Future<Map<String, dynamic>?> _registerPush() async {
    try {
      if (!_isPushSupported()) {
        debugPrint('[PUSH] Web Push API not supported');
        return null;
      }

      // Запрашиваем разрешение на уведомления
      if (web.Notification.permission != 'granted') {
        final permPromise = web.Notification.requestPermission();
        final perm = await permPromise.toDart;
        if (perm.toDart != 'granted') {
          debugPrint('[PUSH] Notification permission denied');
          return null;
        }
      }

      // Вызываем JS функцию registerPush из push_helper.js
      final result = await _registerPushJS().toDart;
      if (result == null) {
        debugPrint('[PUSH] JS registerPush returned null');
        return null;
      }

      // dartify может бросить FormatException если результат не JSON-объект
      dynamic dartValue;
      try {
        dartValue = result.dartify();
      } catch (e) {
        debugPrint('[PUSH] Failed to dartify registerPush result: $e');
        debugPrint('[PUSH] Raw result type: ${result.runtimeType}');
        return null;
      }

      if (dartValue == null) {
        debugPrint('[PUSH] JS registerPush result dartify is null');
        return null;
      }

      final map = (dartValue as Map).cast<String, dynamic>();
      debugPrint('[PUSH] Subscribed, endpoint: ${map['endpoint']}');
      return map;
    } catch (e) {
      debugPrint('[PUSH] Registration error: $e');
      return null;
    }
  }

  Future<void> _sendToGateway(Map<String, dynamic> subscription) async {
    try {
      final success = await _sendSubscriptionToGatewayJS(
        subscription.jsify() as JSObject,
      ).toDart;
      debugPrint(
          '[PUSH] Gateway registration: ${success.toDart ? 'OK' : 'FAILED'}');
    } catch (e) {
      debugPrint('[PUSH] Gateway send error: $e');
    }
  }

  Future<void> _registerPusherOnConduit(
      Client client, String pushkey) async {
    try {
      final deviceName = _detectDeviceName();
      await client.postPusher(
        Pusher(
          pushkey: pushkey,
          kind: 'http',
          appId: 'com.xemooll.private_messenger',
          appDisplayName: 'Private Messenger',
          deviceDisplayName: deviceName,
          lang: 'ru',
          data: PusherData(
            format: 'event_id_only',
            url: Uri.parse('$_pushGatewayUrl/_matrix/push/v1/notify'),
          ),
        ),
        append: true,
      );
      debugPrint('[PUSH] Pusher registered on Conduit for device: $deviceName');
    } catch (e) {
      debugPrint('[PUSH] Conduit pusher registration error: $e');
    }
  }

  bool _isPushSupported() {
    try {
      web.window.navigator.serviceWorker; // Проверяем что свойство существует
      return true;
    } catch (_) {
      return false;
    }
  }

  String _detectDeviceName() {
    try {
      final ua = web.window.navigator.userAgent.toLowerCase();
      if (ua.contains('iphone') || ua.contains('ipad')) {
        return 'iPhone (PWA)';
      } else if (ua.contains('mac')) {
        return 'macOS';
      } else if (ua.contains('android')) {
        return 'Android';
      } else if (ua.contains('windows')) {
        return 'Windows';
      } else if (ua.contains('linux')) {
        return 'Linux';
      }
    } catch (_) {}
    return 'Web (PWA)';
  }
}
