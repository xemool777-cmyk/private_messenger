import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../services/matrix_service.dart';
import 'chat_room_screen.dart';
import 'login_screen.dart';
import 'profile_screen.dart';

class ChatsScreen extends StatefulWidget {
  final MatrixService matrixService;
  const ChatsScreen({super.key, required this.matrixService});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  List<Room> _rooms = [];
  StreamSubscription? _syncSub;
  bool _isLoggingOut = false;

  @override
  void initState() {
    super.initState();
    _loadRooms();
    // Слушаем обновления синхронизации для обновления списка чатов
    _syncSub = widget.matrixService.client.onSync.stream.listen((_) => _loadRooms());
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    super.dispose();
  }

  void _loadRooms() {
    if (mounted) {
      setState(() { _rooms = widget.matrixService.client.rooms; });
    }
  }

  Future<void> _createChat() async {
    final TextEditingController userController = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Начать чат"),
          content: TextField(
            controller: userController,
            decoration: const InputDecoration(
              labelText: "Имя пользователя (без @)",
              hintText: "Например: user2",
              prefixIcon: Icon(Icons.person_add),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Отмена"),
            ),
            ElevatedButton(
              onPressed: () async {
                final username = userController.text.trim();
                if (username.isEmpty) return;
                Navigator.pop(context);
                try {
                  final userId = MatrixService.buildUserId(username);
                  await widget.matrixService.client.createRoom(
                    isDirect: true,
                    invite: [userId],
                    preset: CreateRoomPreset.privateChat,
                    name: "Чат с $username",
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Чат создан!")),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Ошибка: $e")),
                    );
                  }
                }
              },
              child: const Text("Создать"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Выход"),
        content: const Text("Вы уверены, что хотите выйти из аккаунта?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Отмена"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Выйти", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() { _isLoggingOut = true; });
    try {
      await widget.matrixService.logout();
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => LoginPage(matrixService: widget.matrixService),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка выхода: $e")),
        );
      }
    } finally {
      if (mounted) setState(() { _isLoggingOut = false; });
    }
  }

  String _formatTime(DateTime date) {
    return "${date.hour}:${date.minute.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Мессенджер", style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProfileScreen(matrixService: widget.matrixService),
                ),
              ).then((_) => _loadRooms()); // Обновить список после возврата
            },
          ),
        ],
      ),
      body: _rooms.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 60, color: Colors.grey[400]),
                  const SizedBox(height: 10),
                  const Text(
                    "Нет чатов",
                    style: TextStyle(color: Colors.grey, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Нажмите + чтобы начать",
                    style: TextStyle(color: Colors.grey, fontSize: 14),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                // Принудительная синхронизация
                await widget.matrixService.client.oneShotSync();
                _loadRooms();
              },
              child: ListView.separated(
                itemCount: _rooms.length,
                separatorBuilder: (ctx, i) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final room = _rooms[index];
                  final lastEvent = room.lastEvent;

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: CircleAvatar(
                      backgroundColor: Colors.indigo[300],
                      child: Text(
                        room.displayname[0].toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    title: Text(
                      room.displayname,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      lastEvent?.body ?? "Нет сообщений",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                    trailing: lastEvent != null
                        ? Text(
                            _formatTime(lastEvent.originServerTs),
                            style: TextStyle(color: Colors.grey[400], fontSize: 12),
                          )
                        : null,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChatRoomScreen(
                            matrixService: widget.matrixService,
                            room: room,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createChat,
        backgroundColor: Colors.indigo,
        child: const Icon(Icons.add_comment_rounded, color: Colors.white),
      ),
    );
  }
}
