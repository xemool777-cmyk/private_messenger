import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../services/matrix_service.dart';
import 'chat_room_screen.dart';
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

  /// Храним notificationCount на момент последнего входа в чат.
  /// Используется для локального вычисления новых непрочитанных:
  /// displayCount = serverCount - entryCount (если serverCount > entryCount).
  /// Это фикс для серверов, которые не сбрасывают notificationCount
  /// при read markers (xemooll.ru).
  final Map<String, int> _notifCountAtEntry = {};

  @override
  void initState() {
    super.initState();
    _loadRooms();
    // Слушаем обновления синхронизации для обновления списка чатов
    _syncSub = widget.matrixService.client.onSync.stream.listen(
      (_) {
        try {
          _loadRooms();
        } catch (e) {
          debugPrint('[CHATS] Error loading rooms: $e');
        }
      },
      onError: (e) {
        debugPrint('[CHATS] Sync stream error: $e');
      },
    );
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    super.dispose();
  }

  /// Показывает количество непрочитанных с учётом того, что могли
  /// быть прочитаны при входе в чат (даже если сервер не сбросил счётчик).
  int _getDisplayCount(Room room) {
    final serverCount = room.notificationCount;
    final entryCount = _notifCountAtEntry[room.id];
    if (entryCount == null) return serverCount; // ещё не заходили — как от сервера
    if (serverCount >= entryCount) {
      return serverCount - entryCount; // только новые после входа
    }
    // Сервер сбросил счётчик (стало меньше, чем при входе) — отдаём как есть
    return serverCount;
  }

  void _loadRooms() {
    if (mounted) {
      setState(() {
        // Приглашения показываем первыми, затем активные чаты
        final invited = <Room>[];
        final joined = <Room>[];
        for (final room in widget.matrixService.client.rooms) {
          if (room.membership == Membership.invite) {
            invited.add(room);
          } else if (room.membership == Membership.join) {
            joined.add(room);
          }
        }
        _rooms = [...invited, ...joined];
      });
    }
  }

  /// Принять приглашение в комнату
  Future<void> _acceptInvite(Room room) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      debugPrint('[CHAT] Accepting invite to ${room.id}');
      await room.join();
      debugPrint('[CHAT] Joined room ${room.id}');
      _loadRooms();
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatRoomScreen(
              matrixService: widget.matrixService,
              room: room,
            ),
          ),
        );
        _loadRooms();
      }
    } catch (e) {
      debugPrint('[CHAT] Accept invite error: $e');
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Ошибка принятия приглашения: $e')),
        );
      }
    }
  }

  /// Отклонить приглашение
  Future<void> _rejectInvite(Room room) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      debugPrint('[CHAT] Rejecting invite to ${room.id}');
      await room.leave();
      _loadRooms();
    } catch (e) {
      debugPrint('[CHAT] Reject invite error: $e');
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Ошибка: $e')),
        );
      }
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

                      // 1. Создаём комнату через startDirectChat
                      final roomId = await widget.matrixService.client.startDirectChat(
                        userId,
                        enableEncryption: wantEncryption,
                        preset: CreateRoomPreset.privateChat,
                      );

                      debugPrint('[E2EE] Room created: $roomId');

                      // 2. Ждём появления комнаты в локальном списке (до 8 секунд)
                      Room? roomLookup;
                      for (int i = 0; i < 16; i++) {
                        roomLookup = widget.matrixService.client.getRoomById(roomId);
                        if (roomLookup != null) break;
                        await Future.delayed(const Duration(milliseconds: 500));
                        // Принудительный sync для получения комнаты локально
                        await widget.matrixService.client.oneShotSync();
                      }

                      if (roomLookup == null) {
                        debugPrint('[E2EE] Room not found in local state after creation');
                        if (mounted) {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text("Комната создана, но ещё не синхронизирована"),
                              backgroundColor: Colors.orange,
                            ),
                          );
                        }
                        return;
                      }

                      final room = roomLookup;

                      debugPrint('[E2EE] Room found locally, membership: ${room.membership}');

                      // 3. Проверяем шифрование
                      final isEncrypted = room.getState('m.room.encryption') != null;
                      debugPrint('[E2EE] Room encryption state: $isEncrypted');

                      if (wantEncryption && !isEncrypted) {
                        debugPrint('[E2EE] Encryption not in initial state, enabling manually...');
                        try {
                          await room.enableEncryption();
                          debugPrint('[E2EE] Encryption enabled manually');
                        } catch (e) {
                          debugPrint('[E2EE] Manual enable failed: $e');
                        }
                      }

                      // 4. Показываем статус E2EE
                      final e2eeStatus = wantEncryption
                          ? (widget.matrixService.client.encryptionEnabled && isEncrypted
                              ? '🔒 E2EE активен'
                              : '⚠️ Шифрование не включено')
                          : '🔓 Без шифрования';

                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(e2eeStatus),
                            backgroundColor:
                                wantEncryption && isEncrypted ? Colors.green : Colors.orange,
                            duration: const Duration(seconds: 3),
                          ),
                        );
                      }

                      // 5. Авто-переход в созданную комнату
                      if (mounted) {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatRoomScreen(
                              matrixService: widget.matrixService,
                              room: room,
                            ),
                          ),
                        );
                      }
                    } catch (e, stack) {
                      debugPrint('[E2EE] Create chat error: $e');
                      debugPrint('[E2EE] Stack: $stack');
                      // Подробный вывод для bad-json и других ошибок
                      if (e is MatrixException) {
                        debugPrint('[E2EE] MatrixException: ${e.errcode} - ${e.error}');
                      }
                      String msg = '$e';
                      // Укоротить сообщение для SnackBar
                      if (msg.contains('FormatException') || msg.contains('bad') || msg.contains('JSON') || msg.contains('json')) {
                        msg = 'Ошибка сервера (bad JSON). Попробуйте позже.';
                      } else if (msg.length > 80) {
                        msg = '${msg.substring(0, 80)}...';
                      }
                      if (mounted) {
                        messenger.showSnackBar(
                          SnackBar(
                            content: Text(msg),
                            duration: const Duration(seconds: 4),
                          ),
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

  String _formatTime(DateTime date) {
    return "${date.hour}:${date.minute.toString().padLeft(2, '0')}";
  }

  String _safeFirstChar(String name) {
    if (name.isEmpty) return '?';
    return name[0].toUpperCase();
  }

  /// Удаление чата (покинуть комнату + забыть)
  Future<void> _deleteChat(Room room) async {
    final messenger = ScaffoldMessenger.of(context);
    final roomId = room.id;
    final roomName = room.getLocalizedDisplayname();
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
      // 1. LEAVE — покидаем комнату (используем room.leave(), он обновляет локальное состояние)
      if (room.membership == Membership.join || room.membership == Membership.invite) {
        try {
          await room.leave();
          debugPrint('[CHAT] Left room $roomId via room.leave()');
        } catch (e) {
          debugPrint('[CHAT] room.leave() error: $e');
          // Fallback: прямой HTTP-запрос
          try {
            await widget.matrixService.client.leaveRoom(roomId);
            debugPrint('[CHAT] Left room via client.leaveRoom() $roomId');
          } catch (e2) {
            debugPrint('[CHAT] client.leaveRoom() also failed: $e2');
          }
        }
      }

      // 2. FORGET — удаляем комнату полностью (только если выбрано "Удалить")
      if (confirm == 'forget') {
        try {
          await room.forget();
          debugPrint('[CHAT] Forgot room $roomId via room.forget()');
        } catch (e) {
          debugPrint('[CHAT] room.forget() error: $e');
          // Fallback
          try {
            await widget.matrixService.client.forgetRoom(roomId);
            debugPrint('[CHAT] Forgot room via client.forgetRoom() $roomId');
          } catch (e2) {
            debugPrint('[CHAT] client.forgetRoom() also failed: $e2');
          }
        }
      }

      // 3. НЕМЕДЛЕННО удаляем комнату из локального списка, чтобы она не вернулась со следующим sync
      setState(() {
        _rooms.removeWhere((r) => r.id == roomId);
      });

      // 4. Принудительно синхронизируемся, чтобы серверная сторона подтвердила действие
      try {
        await widget.matrixService.client.oneShotSync();
      } catch (e) {
        debugPrint('[CHAT] Post-leave sync warning: $e');
      }
      // Обновляем список после sync
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
                  final isInvite = room.membership == Membership.invite;
                  final lastEvent = room.lastEvent;
                  final isEncrypted = room.getState('m.room.encryption') != null;

                  // --- Приглашение ---
                  if (isInvite) {
                    // Определяем имя пригласившего
                    String inviterName = room.getLocalizedDisplayname();
                    try {
                      final members = room.getParticipants();
                      for (final member in members) {
                        if (member.membership == Membership.join) {
                          inviterName = member.calcDisplayname() ?? inviterName;
                          break;
                        }
                      }
                    } catch (_) {}
                    // Если имя == ID (не удалось разрешить), берём localpart
                    if (inviterName.startsWith('@')) {
                      inviterName = inviterName.substring(1).split(':')[0];
                    }

                    return Container(
                      color: Colors.orange.withOpacity(0.08),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        leading: CircleAvatar(
                          backgroundColor: Colors.orange[700],
                          child: const Icon(Icons.mail_outline, color: Colors.white, size: 20),
                        ),
                        title: Text(
                          inviterName,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          'Приглашает вас в чат',
                          style: TextStyle(color: Colors.orange),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.check_circle, color: Colors.green),
                              tooltip: 'Принять',
                              onPressed: () => _acceptInvite(room),
                            ),
                            IconButton(
                              icon: const Icon(Icons.cancel, color: Colors.red),
                              tooltip: 'Отклонить',
                              onPressed: () => _rejectInvite(room),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  // --- Обычная комната (joined) ---
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
                  } else if (lastEvent.type.startsWith('m.call.')) {
                    // Call events don't have a body — SDK returns "Unknown message format"
                    lastMessageText = lastEvent.type.endsWith('invite') || lastEvent.type.endsWith('answer')
                        ? 'Звонок'
                        : 'Завершённый звонок';
                  } else {
                    lastMessageText = lastEvent.body;
                  }

                    final notifCount = _getDisplayCount(room);
                    final highlightCount = room.highlightCount;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      leading: CircleAvatar(
                        backgroundColor: isEncrypted ? Colors.green[700] : Colors.indigo[300],
                        child: isEncrypted
                            ? const Icon(Icons.lock, color: Colors.white, size: 20)
                             : Text(
                                _safeFirstChar(room.getLocalizedDisplayname()),
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              room.getLocalizedDisplayname(),
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
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (notifCount > 0)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: highlightCount > 0 ? Colors.red : Colors.indigo,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                notifCount > 99 ? '99+' : '$notifCount',
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ),
                          if (notifCount > 0) const SizedBox(width: 8),
                          if (lastEvent != null)
                            Text(
                              _formatTime(lastEvent.originServerTs),
                              style: TextStyle(color: Colors.grey[400], fontSize: 12),
                            ),
                        ],
                      ),
                      onTap: () async {
                        // Запоминаем notificationCount на момент входа в чат
                        _notifCountAtEntry[room.id] = room.notificationCount;
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatRoomScreen(
                              matrixService: widget.matrixService,
                              room: room,
                            ),
                          ),
                        );
                        _loadRooms();
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
