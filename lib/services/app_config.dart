import 'package:flutter/foundation.dart' show kIsWeb;
import 'app_config_web.dart' if (dart.library.io) 'app_config_native.dart';

/// Утилита для чтения конфигурации приложения
///
/// Приоритет конфигурации:
/// 1. Runtime (web): window.__APP_CONFIG из config.js (генерируется entrypoint.sh)
/// 2. Compile-time: --dart-define=HOMESERVER_URL=...
/// 3. Web дефолт: текущий хост (same-origin через nginx proxy)
/// 4. Native дефолт: https://xemooll.ru
class AppConfig {
  /// Homeserver URL с учётом приоритетов
  static String get homeserverUrl {
    // 1. Runtime конфигурация (web: config.js → window.__APP_CONFIG)
    final runtime = getHomeserverUrlFromRuntime();
    if (runtime != null && runtime.isNotEmpty) {
      return runtime;
    }
    // 2. Compile-time --dart-define или дефолт
    return const String.fromEnvironment(
      'HOMESERVER_URL',
      defaultValue: 'https://xemooll.ru',
    );
  }

  /// Server name (домен homeserver)
  static String get serverName {
    // 1. Runtime конфигурация
    final runtime = getServerNameFromRuntime();
    if (runtime != null && runtime.isNotEmpty) {
      return runtime;
    }
    // 2. Извлекаем из URL
    try {
      final uri = Uri.parse(homeserverUrl);
      return uri.host;
    } catch (_) {
      return 'xemooll.ru';
    }
  }
}
