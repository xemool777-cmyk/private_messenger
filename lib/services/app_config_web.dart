/// Чтение конфигурации из window.__APP_CONFIG (web реализация)
/// Этот файл импортируется только на веб-платформе
@JS()
library app_config_web;

import 'dart:html' show window;
import 'package:js/js.dart';

/// Доступ к window.__APP_CONFIG объекту
@JS('__APP_CONFIG')
external _AppConfig? get _appConfig;

@JS()
class _AppConfig {
  external String? get homeserverUrl;
  external String? get serverName;
}

/// Читает homeserverUrl из runtime-конфигурации (config.js)
/// Если пустой — возвращает текущий хост (same-origin) для проксирования через nginx
String? getHomeserverUrlFromRuntime() {
  final url = _appConfig?.homeserverUrl;
  if (url != null && url.isNotEmpty) return url;
  // Пустой homeserverUrl = использовать текущий хост (same-origin proxy)
  // Matrix API запросы пойдут через app.xemooll.ru/_matrix/ → nginx → xemooll.ru
  return '${window.location.origin}';
}

/// Читает serverName из runtime-конфигурации (config.js)
String? getServerNameFromRuntime() => _appConfig?.serverName;
