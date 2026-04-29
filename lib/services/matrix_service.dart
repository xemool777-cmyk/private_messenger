import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';

/// Сервис управления Matrix клиентом
/// Отвечает за инициализацию, логин, регистрацию, синхронизацию
class MatrixService {
  static const String homeserverUrl = 'https://xemooll.ru';
  static const String serverName = 'xemooll.ru';

  late final Client _client;
  Client get client => _client;

  /// Инициализация: Matrix клиент с Hive базой данных
  Future<void> init() async {
    _client = Client(
      'PrivateMessenger',
      databaseBuilder: (_) async {
        final dir = await getApplicationSupportDirectory();
        final db = HiveCollectionsDatabase('private_messenger_db', dir.path);
        await db.open();
        return db;
      },
    );

    // Инициализация клиента — запускает синхронизацию если уже залогинен
    await _client.init();
  }

  /// Проверка — пользователь уже залогинен?
  bool get isLogged => _client.isLogged();

  /// Подключение к homeserver
  Future<void> connectToHomeserver() async {
    await _client.checkHomeserver(Uri.parse(homeserverUrl));
  }

  /// Логин пользователя
  /// После login() синхронизация запускается автоматически
  Future<void> login(String username, String password) async {
    await connectToHomeserver();

    try {
      await _client.login(
        LoginType.mLoginPassword,
        password: password,
        identifier: AuthenticationUserIdentifier(user: username),
      );
    } on MatrixException catch (e) {
      if (e.errcode == 'M_FORBIDDEN' || e.errcode == 'M_USER_IN_USE') {
        // Автоматическая регистрация если логин не удался
        await _client.register(
          username: username,
          password: password,
          auth: AuthenticationData.fromJson({'type': 'm.login.dummy'}),
        );
      } else {
        rethrow;
      }
    }
    // Синхронизация запускается автоматически через init() внутри login()
  }

  /// Восстановление сессии (если уже залогинен при запуске)
  /// init() уже вызван в init(), поэтому сессия восстанавливается автоматически
  Future<void> resumeSession() async {
    if (_client.isLogged()) {
      if (_client.homeserver == null) {
        await connectToHomeserver();
      }
      // Один ручной sync чтобы обновить данные
      await _client.oneShotSync();
    }
  }

  /// Выход из аккаунта
  Future<void> logout() async {
    await _client.logout();
  }

  /// Формирование полного Matrix ID
  static String buildUserId(String username) {
    return '@$username:$serverName';
  }
}
