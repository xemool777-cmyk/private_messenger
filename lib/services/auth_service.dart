import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../config/app_config.dart';
import 'notification_service.dart';

/// Сервис авторизации: логин, регистрация, восстановление сессии, выход.
class AuthService {
  final Client _client;

  /// Кэшированный userId
  String? _cachedUserId;
  String get userId => _cachedUserId ?? _client.userID ?? '';
  bool get isLogged => _client.isLogged();

  AuthService(this._client);

  /// Подключение к homeserver с ретраем
  Future<void> connectToHomeserver() async {
    try {
      debugPrint('[Matrix] Checking homeserver: ${AppConfig.homeserverUrl}');
      await _client.checkHomeserver(Uri.parse(AppConfig.homeserverUrl));
      debugPrint('[Matrix] Homeserver OK: ${_client.homeserver}');
    } catch (e) {
      debugPrint('[Matrix] checkHomeserver failed: $e');
      await Future.delayed(const Duration(seconds: 1));
      try {
        debugPrint('[Matrix] Retry homeserver check...');
        await _client.checkHomeserver(Uri.parse(AppConfig.homeserverUrl));
        debugPrint('[Matrix] Retry OK');
      } catch (e2) {
        debugPrint('[Matrix] Retry also failed: $e2');
        rethrow;
      }
    }
  }

  /// Логин пользователя. Если M_FORBIDDEN — пытается зарегистрировать.
  Future<void> login(String username, String password) async {
    if (_client.isLogged()) {
      debugPrint('[Matrix] Already logged in, skipping login');
      _cachedUserId = _client.userID;
      return;
    }

    await connectToHomeserver();

    try {
      debugPrint('[Matrix] Attempting login for user: $username');
      await _client.login(
        LoginType.mLoginPassword,
        password: password,
        identifier: AuthenticationUserIdentifier(user: username),
      );
      debugPrint('[Matrix] Login SUCCESS, userId: ${_client.userID}');
    } on MatrixException catch (e) {
      debugPrint('[Matrix] Login MatrixException: ${e.error}, errcode: ${e.errcode}');
      if (e.errcode == 'M_FORBIDDEN' || e.errcode == 'M_USER_IN_USE') {
        debugPrint('[Matrix] Trying registration...');
        await _client.register(
          username: username,
          password: password,
          auth: AuthenticationData.fromJson({'type': 'm.login.dummy'}),
        );
      } else {
        rethrow;
      }
    } catch (e) {
      debugPrint('[Matrix] Login general error: $e');
      rethrow;
    }
    _cachedUserId = _client.userID;
    debugPrint('[Matrix] After login: userID = $_cachedUserId');

    // Push Subscription (Web Push + Matrix Pusher)
    await NotificationService.instance.setupPushSubscription(_client);

    // E2EE диагностика после логина
    debugPrint('[Matrix] After login: encryptionEnabled = ${_client.encryptionEnabled}');
    if (_client.encryptionEnabled) {
      debugPrint('[Matrix] E2EE WORKING! Identity key: ${_client.identityKey}');
      debugPrint('[Matrix] E2EE WORKING! Fingerprint key: ${_client.fingerprintKey}');
    } else {
      debugPrint('[Matrix] WARNING: E2EE is NOT enabled after login!');
    }
  }

  /// Восстановление сессии при запуске
  Future<void> resumeSession() async {
    if (_client.isLogged()) {
      if (_client.homeserver == null) {
        await connectToHomeserver();
      }
      await _client.oneShotSync();

      // Регистрируем push-подписку при восстановлении сессии
      await NotificationService.instance.setupPushSubscription(_client);

      debugPrint('[Matrix] Session restored: encryptionEnabled = ${_client.encryptionEnabled}');
      if (_client.encryptionEnabled) {
        debugPrint('[Matrix] E2EE OK after session restore. Identity: ${_client.identityKey}');
      } else {
        debugPrint('[Matrix] WARNING: E2EE not enabled after session restore!');
      }
    }
  }

  /// Выход из аккаунта
  Future<void> logout() async {
    await NotificationService.instance.removePushSubscription();
    await _client.logout();
    await NotificationService.instance.cancelAllNotifications();
  }
}
