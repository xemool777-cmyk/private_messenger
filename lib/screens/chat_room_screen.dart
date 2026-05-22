import 'dart:async';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    widget.matrixService.currentRoomId = widget.room.id;
    NotificationService.instance.cancelNotification(widget.room.id);

    _initTimeline();

    _keyReceivedSub = widget.room.onSessionKeyReceived.stream.listen((_) {
      if (mounted) setState(() {});
    });

    // Критично: room.onUpdate не всегда срабатывает для новых сообщений в SDK 0.22
    // client.onSync гарантированно срабатывает при каждом sync
    _syncSub = widget.matrixService.client.onSync.stream.listen((syncUpdate) {
      if (!mounted) return;
      final joinedRooms = syncUpdate.rooms?.join;
      if (joinedRooms == null) return;
      if (joinedRooms.containsKey(widget.room.id)) {
        setState(() {});
        // Прокрутить вниз если мы были внизу списка
        _scrollToBottomIfNearEnd();
        // Отмечаем новые сообщения прочитанными
        _markAsRead();
      }
    });
  }

  @override
  void dispose() {
    widget.matrixService.currentRoomId = null;
    _keyReceivedSub?.cancel();
    _syncSub?.cancel();
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

  void _showMessageActions(Event event, bool isMe) {
    final isFailed = isMe && event.status == EventStatus.error;

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
              ListTile(
                leading: const Icon(Icons.reply, color: Colors.indigo),
                title: const Text("Ответить"),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _setReplyTo(event);
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
                onTap: () {
                  Navigator.pop(sheetContext);
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
        title: Row(
          children: [
            Flexible(child: Text(widget.room.getLocalizedDisplayname())),
            if (widget.room.getState('m.room.encryption') != null) ...[
              const SizedBox(width: 6),
              Icon(Icons.lock, size: 16, color: Colors.green[200]),
            ],
          ],
        ),
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
                      ),
          ),
          // Input bar
          InputBar(
            room: widget.room,
            replyToEvent: _replyToEvent,
            isSending: _isSending,
            onReplyCleared: _cancelReply,
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
