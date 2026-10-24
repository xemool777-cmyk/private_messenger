import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:record_web/record_web.dart';
import 'services/matrix_service.dart';
import 'services/keys_service.dart';
import 'services/notification_service.dart';
import 'services/call_service.dart';
import 'screens/login_screen.dart';
import 'screens/chats_screen.dart';
import 'screens/chat_room_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Глобальный обработчик ошибок — ловим всё, что прошло мимо try-catch
  FlutterError.onError = (details) {
    // Игнорируем overflow-ошибки (безобидны в web)
    if (details.exception is FlutterError &&
        details.exception.toString().contains('overflow')) {
      debugPrint('[ERROR] Overflow ignored: ${details.exception}');
      return;
    }
    debugPrint('[ERROR] FLUTTER: ${details.exception}\n${details.stack}');
  };

  // Вместо серого экрана — показываем ошибку пользователю
  ErrorWidget.builder = (details) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.red[50],
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                const Text('Ошибка приложения',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.red)),
                const SizedBox(height: 8),
                Text(details.exceptionAsString(),
                    style: const TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: Colors.black87)),
              ],
            ),
          ),
        ),
      ),
    );
  };

  // Зона для необработанных асинхронных ошибок
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // record_web plugin auto-registration may not trigger — manual fallback
    if (kIsWeb) {
      RecordPlatform.instance = RecordPluginWebWrapper();
    }

    debugPrint('[INIT] Creating MatrixService...');
    final matrixService = MatrixService();

    debugPrint('[INIT] Running app immediately (init in background)...');
    runApp(MyApp(matrixService: matrixService));
  }, (error, stack) {
    debugPrint('[ERROR] UNHANDLED ASYNC: $error\n$stack');
  });
}

class MyApp extends StatefulWidget {
  final MatrixService matrixService;
  const MyApp({super.key, required this.matrixService});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription? _notifSub;
  bool _initializing = true;
  Object? _initError;

  @override
  void initState() {
    super.initState();
    // Слушаем нажатия на уведомления
    _notifSub =
        NotificationService.instance.onNotificationTapped.listen((roomId) {
      _openChatFromNotification(roomId);
    });
    // Стартуем инициализацию Matrix в фоне после отрисовки первого кадра,
    // чтобы интерфейс (экран загрузки) появился сразу.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initMatrix());
    });
  }

  Future<void> _initMatrix() async {
    if (!mounted) return;
    setState(() {
      _initializing = true;
      _initError = null;
    });

    debugPrint('[INIT] Calling matrixService.init()...');
    try {
      await widget.matrixService.init();
      debugPrint('[INIT] matrixService.init() OK');

      if (!KeysService.vodozemacReady) {
        debugPrint('═══════════════════════════════════════════════════════');
        debugPrint('⚠️  VODOZEMAC NOT INITIALIZED — E2EE WILL NOT WORK');
        debugPrint('   Web: check that olm.wasm is in web/pkg/ directory');
        debugPrint('   Native: check libolm.so is bundled correctly');
        debugPrint('═══════════════════════════════════════════════════════');
      }

      // Разблокируем аудио-контекст (для рингтона входящих звонков)
      CallService.unlockAudio();

      if (!mounted) return;
      setState(() {
        _initializing = false;
      });
    } catch (e, stack) {
      debugPrint('[INIT] matrixService.init() FAILED: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _initError = e;
      });
    }
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    super.dispose();
  }

  /// Открыть чат при нажатии на уведомление
  void _openChatFromNotification(String roomId) {
    if (_initializing || _initError != null) return;
    final client = widget.matrixService.client;
    final room = client.getRoomById(roomId);
    if (room == null) return;

    final context = navigatorKey.currentContext;
    if (context == null) return;

    // Сначала переходим на список чатов, потом в нужный чат
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => ChatsScreen(matrixService: widget.matrixService),
      ),
      (route) => route.isFirst,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          matrixService: widget.matrixService,
          room: room,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Private Messenger',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
        ),
      ),
      home: _initializing
          ? const _StartupLoadingScreen()
          : _initError != null
              ? _StartupErrorScreen(
                  error: _initError!,
                  onRetry: () => unawaited(_initMatrix()),
                )
              : LoginPage(matrixService: widget.matrixService),
    );
  }
}

class _StartupLoadingScreen extends StatelessWidget {
  const _StartupLoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Подключение к серверу...'),
          ],
        ),
      ),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _StartupErrorScreen({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 56, color: Colors.red),
                const SizedBox(height: 16),
                const Text(
                  'Не удалось подключиться',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  '$error',
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Повторить'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
