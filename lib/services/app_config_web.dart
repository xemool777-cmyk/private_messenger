/// Чтение конфигурации из window.__APP_CONFIG (web реализация)
/// Этот файл импортируется только на веб-платформе
@JS()
library app_config_web;

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
String? getHomeserverUrlFromRuntime() => _appConfig?.homeserverUrl;

/// Читает serverName из runtime-конфигурации (config.js)
String? getServerNameFromRuntime() => _appConfig?.serverName;
