import 'dart:async';
import 'package:flutter/material.dart';
import 'services/matrix_service.dart';
import 'services/notification_service.dart';
import 'screens/login_screen.dart';
import 'screens/chats_screen.dart';
import 'screens/chat_room_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final matrixService = MatrixService();
  await matrixService.init();

  runApp(MyApp(matrixService: matrixService));
}

class MyApp extends StatefulWidget {
  final MatrixService matrixService;
  const MyApp({super.key, required this.matrixService});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription? _notifSub;

  @override
  void initState() {
    super.initState();
    // Слушаем нажатия на уведомления
    _notifSub = NotificationService.instance.onNotificationTapped.listen((roomId) {
      _openChatFromNotification(roomId);
    });
  }

  @override
  void dispose() {
    _notifSub?.cancel();
    super.dispose();
  }

  /// Открыть чат при нажатии на уведомление
  void _openChatFromNotification(String roomId) {
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
      home: LoginPage(matrixService: widget.matrixService),
    );
  }
}
