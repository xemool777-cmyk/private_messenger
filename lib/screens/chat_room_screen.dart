import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import '../services/matrix_service.dart';
import '../services/notification_service.dart';
import '../widgets/timeline_list.dart';
import '../widgets/input_bar.dart';
import '../widgets/fullscreen_image.dart';

class ChatRoomScreen extends StatefulWidget {
  final MatrixService matrixService;
  final Room room;
  const ChatRoomScreen({super.key, required this.matrixService, required this.room});

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final _scrollController = ScrollController();
  Timeline? _timeline;
  bool _isLoading = true;
  bool _isLoadingHistory = false;
  bool _isSending = false;
  StreamSubscription? _keyReceivedSub;
  StreamSubscription? _syncSub;
  bool _canLoadMoreHistory = true;

  Event? _replyToEvent;
  Event? _editEvent;  // событие, которое редактируем

  // ---- Typing indicators (P2.7) ----
  List<User> _typingUsers = [];
  StreamSubscription? _typingSub;

  // ---- Reaction tracking ----
  /// Фингерпринт реакций: eventId → общее число реакций.
  /// Сравнивается при каждом sync — при изменении показываем уведомление.
  Map<String, int> _lastReactionFingerprint = {};
  bool _reactionsInitialized = false;

  @override
  void initState() {
    super.initState();
    widget.matrixService.currentRoomId = widget.room.id;
    NotificationService.instance.cancelNotification(widget.room.id);

    // Fire-and-forget with explicit error boundary — prevent gray screen
    _initTimeline().catchError((e, s) {
      debugPrint('[CHAT] _initTimeline UNHANDLED: $e\n$s');
      if (mounted) setState(() { _isLoading = false; });
    });

    _keyReceivedSub = widget.room.onSessionKeyReceived.stream.listen((_) {
      if (mounted) setState(() {});
    }, onError: (e, s) {
      debugPrint('[CHAT] onSessionKeyReceived stream error: $e\n$s');
    });

    // Критично: room.onUpdate не всегда срабатывает для новых сообщений в SDK 0.22
    // client.onSync гарантированно срабатывает при каждом sync
    _syncSub = widget.matrixService.client.onSync.stream.listen((syncUpdate) {
      if (!mounted) return;
      try {
        final joinedRooms = syncUpdate.rooms?.join;
        if (joinedRooms == null) return;
        if (joinedRooms.containsKey(widget.room.id)) {
          _checkReactionChanges();
          setState(() {});
          _scrollToBottomIfNearEnd();
          _markAsRead();
        }
      } catch (e) {
        debugPrint('[CHAT] Sync listener error: $e');
      }
    });

    // ---- Room update listener (fake syncs, typing, sending status) ----
    _typingSub = widget.room.onUpdate.stream.listen((_) {
      if (!mounted) return;
      try {
        final typing = widget.room.typingUsers
            .where((u) => u != widget.matrixService.client.userID)
            .toList();
        final typingChanged = _typingUsers.join() != typing.join();
        if (typingChanged) {
          _typingUsers = typing;
        }
        setState(() {});
      } catch (e) {
        debugPrint('[CHAT] Typing listener error: $e');
      }
    });
  }

  @override
  void dispose() {
    widget.matrixService.currentRoomId = null;
    _keyReceivedSub?.cancel();
    _syncSub?.cancel();
    _typingSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // ===================== TIMELINE =====================

  Future<void> _initTimeline() async {
    if (!mounted) return;
    try {
      try {
        await widget.room.postLoad();
      } catch (e) {
        debugPrint("[CHAT] postLoad warning: $e");
      }

      final timeline = await widget.room.getTimeline();
      _timeline = timeline;

      await _requestMoreHistory();

      // Отмечаем чат прочитанным (fire-and-forget, ошибки ловятся внутри)
      _markAsRead();

      if (mounted) {
        setState(() { _isLoading = false; });
        _scrollToBottom();
      }

      final isEncrypted = widget.room.getState('m.room.encryption') != null;
      if (isEncrypted && _timeline != null) {
        final undecrypted = _timeline!.events.where(
          (e) => e.type == EventTypes.Encrypted || e.messageType == MessageTypes.BadEncrypted
        ).length;
        if (undecrypted > 0) {
          try {
            _timeline!.requestKeys();
            if (mounted) setState(() {});
          } catch (e) {
            debugPrint('[E2EE] Key request failed: $e');
          }
        }
      }

      _scrollController.addListener(() {
        onScrollToLoadHistory(
          _scrollController, _canLoadMoreHistory, _isLoadingHistory, _loadMoreHistory,
        );
      });
    } catch (e) {
      debugPrint("Timeline init error: $e");
      if (mounted) setState(() { _isLoading = false; });
    }
  }

  Future<void> _requestMoreHistory() async {
    if (_timeline == null || !_canLoadMoreHistory) return;
    try {
      final countBefore = _timeline!.events.length;
      await _timeline!.requestHistory();
      if (_timeline!.events.length == countBefore) {
        _canLoadMoreHistory = false;
      }
    } catch (e) {
      debugPrint("History request error: $e");
    }
  }

  Future<void> _loadMoreHistory() async {
    if (_isLoadingHistory || !_canLoadMoreHistory) return;
    setState(() { _isLoadingHistory = true; });
    try {
      await _requestMoreHistory();
    } finally {
      if (mounted) setState(() { _isLoadingHistory = false; });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.minScrollExtent);
      }
    });
  }

  /// Отправить read marker на сервер — сбрасывает notificationCount
  void _markAsRead() {
    final events = _timeline?.events ?? [];
    if (events.isEmpty) return;
    final lastEvent = events.first;
    final eventId = lastEvent.eventId;
    // Не спамим одним и тем же eventId
    if (eventId == _lastReadEventId) return;
    _lastReadEventId = eventId;
    debugPrint('[CHAT] Read marker set for event: $eventId');
    // setReadMarker — Future, ловим ошибку через .catchError
    widget.room.setReadMarker(eventId).catchError((e) {
      debugPrint('[CHAT] setReadMarker error (non-critical): $e');
    });
  }

  String? _lastReadEventId; // защита от повторной отправки для того же event

  /// Прокрутить вниз, если пользователь был рядом с нижним краем
  void _scrollToBottomIfNearEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final pos = _scrollController.position;
        // Если мы рядом с низом (новые сообщения) — проскроллить вниз
        if (pos.pixels <= pos.minScrollExtent + 200) {
          _scrollController.jumpTo(pos.minScrollExtent);
        }
      }
    });
  }

  bool _hasUndecryptedEvents() {
    if (_timeline == null) return false;
    return _timeline!.events.any(
      (e) => e.type == EventTypes.Encrypted || e.messageType == MessageTypes.BadEncrypted
    );
  }

  // ===================== ACTIONS =====================

  void _setReplyTo(Event event) {
    setState(() { _replyToEvent = event; });
  }

  void _cancelReply() {
    setState(() { _replyToEvent = null; });
  }

  void _setEditTo(Event event) {
    setState(() {
      _replyToEvent = null;
      _editEvent = event;
    });
  }

  void _cancelEdit() {
    setState(() { _editEvent = null; });
  }

  Future<void> _resendEvent(Event event) async {
    try {
      await event.sendAgain();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Повторная отправка..."), backgroundColor: Colors.blue),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _removeEvent(Event event) async {
    try {
      await event.cancelSend();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint("Remove event error: $e");
    }
  }

  Future<void> _redactEvent(Event event) async {
    try {
      await widget.room.redactEvent(event.eventId);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка удаления: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Сравнивает текущие реакции с предыдущим состоянием.
  /// Если есть изменения (новая/удалённая реакция) — показывает SnackBar.
  void _checkReactionChanges() {
    final tl = _timeline;
    if (tl == null) return;

    final Map<String, int> current = {};
    for (final event in tl.events) {
      try {
        if (event.type != EventTypes.Message && event.type != EventTypes.Encrypted) continue;
        if (event.messageType == MessageTypes.BadEncrypted) continue;
        final reactions = event.aggregatedEvents(tl, RelationshipTypes.reaction);
        if (reactions.isNotEmpty) {
          current[event.eventId] = reactions.length;
        }
      } catch (_) {
        // Пропускаем события, которые не удалось обработать
      }
    }

    // Ищем изменения в любую сторону
    bool hasChanges = false;
    for (final entry in current.entries) {
      final prev = _lastReactionFingerprint[entry.key] ?? 0;
      if (entry.value != prev) {
        hasChanges = true;
        break;
      }
    }
    // Проверяем также удалённые реакции (eventId который был, а теперь нет)
    if (!hasChanges) {
      for (final key in _lastReactionFingerprint.keys) {
        if (!current.containsKey(key)) {
          hasChanges = true;
          break;
        }
      }
    }

    _lastReactionFingerprint = current;

    // Показываем уведомление только если уже была инициализация
    if (!_reactionsInitialized) {
      _reactionsInitialized = true;
      return;
    }

    if (hasChanges && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Новые реакции в чате", style: TextStyle(fontSize: 13)),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(bottom: 80, left: 16, right: 16),
        ),
      );
    }
  }

  /// Отправить/отозвать реакцию (P2.6)
  Future<void> _sendReaction(Event event, String emoji) async {
    try {
      final tl = _timeline;
      if (tl == null) return;

      final existingReactions = event.aggregatedEvents(tl, RelationshipTypes.reaction);
      final existing = existingReactions.where(
        (e) =>
            (e.content['m.relates_to'] as Map<String, dynamic>?)?['key'] ==
            emoji,
      );

      if (existing.isNotEmpty) {
        // Toggle off: redact existing reaction
        await widget.room.redactEvent(existing.first.eventId);
      } else {
        // Use SDK's built-in sendReaction
        await widget.room.sendReaction(event.eventId, emoji);
      }
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка реакции: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showMessageActions(Event event, bool isMe) {
    final isFailed = isMe && event.status == EventStatus.error;
    final isText = event.messageType == MessageTypes.Text;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 12),
              if (event.body.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    event.body,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                ),
              if (event.body.isNotEmpty) const SizedBox(height: 12),
               // ---- Emoji reactions row (P2.6) ----
               Padding(
                 padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                 child: Wrap(
                   spacing: 12,
                   runSpacing: 8,
                   children: ['👍', '❤️', '😂', '😮', '😢', '😡', '🎉', '👎', '😍', '🤔', '👀', '💯', '🔥', '🙌', '🥳', '🤯', '😱', '💪', '🙏', '😭'].map((emoji) {
                     return GestureDetector(
                       onTap: () {
                         Navigator.pop(sheetContext);
                         _sendReaction(event, emoji);
                       },
                       child: Text(emoji, style: const TextStyle(fontSize: 27)),
                     );
                   }).toList(),
                 ),
               ),
              const SizedBox(height: 4),
              ListTile(
                leading: const Icon(Icons.reply, color: Colors.indigo),
                title: const Text("Ответить"),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _setReplyTo(event);
                },
              ),
              if (isMe && isText && !isFailed)
                ListTile(
                  leading: const Icon(Icons.edit, color: Colors.orange),
                  title: const Text("Редактировать"),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _setEditTo(event);
                  },
                ),
              if (isMe && !isFailed)
                ListTile(
                  leading: const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text("Удалить для всех", style: TextStyle(color: Colors.red)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _redactEvent(event);
                  },
                ),
              if (isFailed) ...[
                ListTile(
                  leading: const Icon(Icons.refresh, color: Colors.blue),
                  title: const Text("Отправить повторно"),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _resendEvent(event);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete, color: Colors.red),
                  title: const Text("Удалить", style: TextStyle(color: Colors.red)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _removeEvent(event);
                  },
                ),
              ],
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.grey),
                title: const Text("Копировать текст"),
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: event.body));
                  if (sheetContext.mounted) {
                    Navigator.pop(sheetContext);
                  }
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text("Текст скопирован"),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  }
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _openFullScreenImage(Event event) {
    final mediaService = widget.matrixService.media;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => FullscreenImageView(
        event: event,
        cachedBytes: mediaService.cache.get(event.eventId),
        mediaService: mediaService,
      ),
    ));
  }

  // ===================== BUILD =====================

  @override
  Widget build(BuildContext context) {
    final client = widget.matrixService.client;
    final events = _timeline?.events ?? [];
    final mediaService = widget.matrixService.media;
    final screenWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      appBar: AppBar(
        title: _typingUsers.isEmpty
            ? Row(
                children: [
                  Flexible(child: Text(widget.room.getLocalizedDisplayname())),
                  if (widget.room.getState('m.room.encryption') != null) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.lock, size: 16, color: Colors.green[200]),
                  ],
                ],
              )
            : Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _typingUsers.length == 1
                          ? '${_typingUsers.first.calcDisplayname()} печатает...'
                          : '${_typingUsers.length} участника печатают...',
                      style: const TextStyle(fontSize: 14, color: Colors.grey, fontStyle: FontStyle.italic),
                    ),
                  ),
                ],
              ),
        actions: [
          // Аудиозвонок
          IconButton(
            icon: const Icon(Icons.phone),
            tooltip: 'Аудиозвонок',
            onPressed: () {
              widget.matrixService.call.inviteToCall(widget.room, CallType.kVoice);
            },
          ),
          // Видеозвонок
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: 'Видеозвонок',
            onPressed: () {
              widget.matrixService.call.inviteToCall(widget.room, CallType.kVideo);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Encryption warning
          if (widget.room.getState('m.room.encryption') == null)
            Container(
              width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), color: Colors.orange[100],
              child: Row(children: [
                Icon(Icons.lock_open, size: 18, color: Colors.orange[800]),
                const SizedBox(width: 8),
                Expanded(child: Text("Сквозное шифрование не включено. Ваши сообщения не защищены.", style: TextStyle(color: Colors.orange[900], fontSize: 12))),
              ]),
            ),
          // Undecrypted banner
          if (widget.room.getState('m.room.encryption') != null && _timeline != null && _hasUndecryptedEvents())
            Container(
              width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), color: Colors.amber[100],
              child: Row(children: [
                Icon(Icons.info_outline, size: 18, color: Colors.amber[800]),
                const SizedBox(width: 8),
                Expanded(child: Text("Некоторые сообщения не удалось расшифровать. Ключи запрошены у ваших других устройств.", style: TextStyle(color: Colors.amber[900], fontSize: 11))),
              ]),
            ),
          // Timeline
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : events.isEmpty
                    ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.chat, size: 48, color: Colors.grey[400]),
                        const SizedBox(height: 8),
                        const Text("Начните разговор!", style: TextStyle(color: Colors.grey, fontSize: 16)),
                      ]))
                    : TimelineList(
                        events: events,
                        currentUserId: client.userID ?? '',
                        canLoadMoreHistory: _canLoadMoreHistory,
                        isLoadingHistory: _isLoadingHistory,
                        scrollController: _scrollController,
                        timeline: _timeline,
                        screenWidth: screenWidth,
                        onReply: _setReplyTo,
                        onLongPress: _showMessageActions,
                        onResend: _resendEvent,
                        onRemove: _removeEvent,
                        onLoadMoreHistory: _loadMoreHistory,
                        mediaService: mediaService,
                        onOpenImage: _openFullScreenImage,
                        isSending: _isSending,
                      ),
          ),
          // Input bar
          InputBar(
            room: widget.room,
            replyToEvent: _replyToEvent,
            editEvent: _editEvent,
            isSending: _isSending,
            onReplyCleared: _cancelReply,
            onEditCleared: _cancelEdit,
            onSendingChanged: () {
              if (mounted) setState(() { _isSending = !_isSending; });
            },
            mediaService: mediaService,
          ),
        ],
      ),
    );
  }
}
