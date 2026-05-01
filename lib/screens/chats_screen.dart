import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      // Показываем только комнаты где мы участник (не покинутые)
      setState(() {
        _rooms = widget.matrixService.client.rooms.where(
          (room) => room.membership == Membership.join,
        ).toList();
      });
    }
  }

  bool _encryptNewChat = true;

  Future<void> _createChat() async {
    final TextEditingController userController = TextEditingController();
    // Сохраняем ScaffoldMessenger ДО показа диалога, чтобы использовать
    // его после закрытия диалога (когда контекст диалога уже деактивирован)
    final messenger = ScaffoldMessenger.of(context);

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: const Text("Начать чат"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: userController,
                    decoration: const InputDecoration(
                      labelText: "Имя пользователя (без @)",
                      hintText: "Например: user2",
                      prefixIcon: Icon(Icons.person_add),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    title: const Text("Шифрование"),
                    subtitle: Text(
                      _encryptNewChat ? "Сообщения зашифрованы" : "Без шифрования",
                      style: TextStyle(
                        color: _encryptNewChat ? Colors.green : Colors.grey,
                        fontSize: 12,
                      ),
                    ),
                    secondary: Icon(
                      _encryptNewChat ? Icons.lock : Icons.lock_open,
                      color: _encryptNewChat ? Colors.green : Colors.grey,
                    ),
                    value: _encryptNewChat,
                    onChanged: (val) => setDialogState(() => _encryptNewChat = val),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text("Отмена"),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final username = userController.text.trim();
                    if (username.isEmpty) return;
                    Navigator.pop(dialogContext);

                    try {
                      final userId = MatrixService.buildUserId(username);
                      final wantEncryption = _encryptNewChat;

                      debugPrint('[E2EE] Creating chat with $userId, encryption=$wantEncryption');
                      debugPrint('[E2EE] client.encryptionEnabled = ${widget.matrixService.client.encryptionEnabled}');

                      // Используем startDirectChat — он корректно создаёт DM
                      // с шифрованием через initialState (без гонки с sync)
                      final roomId = await widget.matrixService.client.startDirectChat(
                        userId,
                        enableEncryption: wantEncryption,
                        preset: CreateRoomPreset.privateChat,
                      );

                      debugPrint('[E2EE] Room created: $roomId');

                      // Проверяем что комната действительно зашифрована
                      if (wantEncryption) {
                        final room = widget.matrixService.client.getRoomById(roomId);
                        final isEncrypted = room?.getState('m.room.encryption') != null;
                        debugPrint('[E2EE] Room encryption state: $isEncrypted');
                        if (!isEncrypted) {
                          debugPrint('[E2EE] Encryption not in initial state, enabling manually...');
                          if (room != null) {
                            try {
                              await room.enableEncryption();
                              debugPrint('[E2EE] Encryption enabled manually');
                            } catch (e) {
                              debugPrint('[E2EE] Manual enable failed: $e');
                            }
                          } else {
                            debugPrint('[E2EE] Room not found yet, waiting for sync...');
                          }
                        }
                      }

                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(wantEncryption ? "Зашифрованный чат создан!" : "Чат создан!"),
                            backgroundColor: Colors.green,
                          ),
                        );
                      }
                    } catch (e) {
                      debugPrint('[E2EE] Create chat error: $e');
                      if (mounted) {
                        messenger.showSnackBar(
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

  /// Удаление чата (покинуть комнату + забыть)
  Future<void> _deleteChat(Room room) async {
    final messenger = ScaffoldMessenger.of(context);
    final roomId = room.id;
    final roomName = room.displayname;
    final confirm = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Удалить чат"),
        content: Text("Покинуть чат «$roomName»?\nСообщения будут удалены только у вас."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("Отмена"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'leave'),
            child: const Text("Покинуть", style: TextStyle(color: Colors.orange)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, 'forget'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Удалить", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == null) return;

    try {
      // Покидаем комнату если ещё участник
      if (room.membership == Membership.join || room.membership == Membership.invite) {
        try {
          await widget.matrixService.client.leaveRoom(roomId);
          debugPrint('[CHAT] Left room $roomId');
        } catch (e) {
          // Возможно уже не участник — не критично
          debugPrint('[CHAT] Leave room error (may be already left): $e');
        }
      }

      // Удаляем (forget) комнату полностью
      if (confirm == 'forget') {
        try {
          await widget.matrixService.client.forgetRoom(roomId);
          debugPrint('[CHAT] Forgot room $roomId');
        } catch (e) {
          debugPrint('[CHAT] Forget room error: $e');
          // Пробуем альтернативный способ
          try {
            await room.forget();
            debugPrint('[CHAT] Forgot room via room.forget() $roomId');
          } catch (e2) {
            debugPrint('[CHAT] Room.forget() also failed: $e2');
          }
        }
      }

      // Обновляем список чатов
      _loadRooms();

      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(confirm == 'forget' ? "Чат удалён" : "Вы покинули чат"),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      debugPrint('[CHAT] Error deleting room: $e');
      // Даже при ошибке обновляем список — комната могла удалиться частично
      _loadRooms();
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text("Ошибка: $e")),
        );
      }
    }
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
                  final isEncrypted = room.getState('m.room.encryption') != null;

                  // Текст последнего сообщения
                  String lastMessageText;
                  if (lastEvent == null) {
                    lastMessageText = "Нет сообщений";
                  } else if (lastEvent.messageType == MessageTypes.BadEncrypted || lastEvent.type == EventTypes.Encrypted) {
                    lastMessageText = "Зашифрованное сообщение";
                  } else if (lastEvent.messageType == MessageTypes.Image) {
                    lastMessageText = "Фото";
                  } else if (lastEvent.messageType == MessageTypes.File) {
                    lastMessageText = "Файл";
                  } else if (lastEvent.messageType == MessageTypes.Audio) {
                    lastMessageText = "Аудио";
                  } else if (lastEvent.messageType == MessageTypes.Video) {
                    lastMessageText = "Видео";
                  } else {
                    lastMessageText = lastEvent.body ?? "Нет сообщений";
                  }

                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    leading: CircleAvatar(
                      backgroundColor: isEncrypted ? Colors.green[700] : Colors.indigo[300],
                      child: isEncrypted
                          ? const Icon(Icons.lock, color: Colors.white, size: 20)
                          : Text(
                              room.displayname[0].toUpperCase(),
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            room.displayname,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (isEncrypted)
                          Icon(Icons.lock, size: 14, color: Colors.green[600]),
                      ],
                    ),
                    subtitle: Text(
                      lastMessageText,
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
                    onLongPress: () => _deleteChat(room),
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
