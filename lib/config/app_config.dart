/// Конфигурация приложения: homeserver URL, server name, утилиты
class AppConfig {
  /// URL Matrix homeserver
  static const String homeserverUrl = 'https://xemooll.ru';

  /// Имя сервера (для построения Matrix ID)
  static const String serverName = 'xemooll.ru';

  /// Построить полный Matrix ID: @username:serverName
  static String buildUserId(String username) => '@$username:$serverName';
}
