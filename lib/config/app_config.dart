/// Конфигурация приложения: homeserver URL, server name, утилиты.
///
/// Значения задаются на сборке, чтобы PWA собиралась под любой homeserver:
///   flutter build web --release \
///     --dart-define=MATRIX_HOMESERVER=https://matrix.example.org \
///     --dart-define=MATRIX_SERVER_NAME=example.org
///
/// Без параметров остаются боевые значения по умолчанию.
class AppConfig {
  /// URL Matrix homeserver
  static const String homeserverUrl = String.fromEnvironment(
    'MATRIX_HOMESERVER',
    defaultValue: 'https://xemooll.ru',
  );

  /// Имя сервера (для построения Matrix ID)
  static const String serverName = String.fromEnvironment(
    'MATRIX_SERVER_NAME',
    defaultValue: 'xemooll.ru',
  );

  /// Построить полный Matrix ID: @username:serverName
  static String buildUserId(String username) => '@$username:$serverName';

  /// true, если сборка нацелена на локальный сервер (http, тестовый контур)
  static bool get isLocalServer => homeserverUrl.startsWith('http://');
}
