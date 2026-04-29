import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../services/matrix_service.dart';

class ChatRoomScreen extends StatefulWidget {
  final MatrixService matrixService;
  final Room room;
  const ChatRoomScreen({super.key, required this.matrixService, required this.room});

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  Timeline? _timeline;
  bool _isLoading = true;
  bool _isLoadingHistory = false;
  bool _isSending = false;
  StreamSubscription? _roomUpdateSub;
  bool _canLoadMoreHistory = true;

  // Кэш загруженных картинок (eventId → байты)
  final Map<String, Uint8List> _imageCache = {};
  // Кэш Future чтобы не дублировать загрузки
  final Map<String, Future<MatrixFile?>> _imageLoadFutures = {};

  @override
  void initState() {
    super.initState();
    _initTimeline();

    // Слушаем обновления комнаты — просто обновляем UI, НЕ пересоздаём таймлайн!
    _roomUpdateSub = widget.room.onUpdate.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _roomUpdateSub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  // ===================== ТАЙМЛАЙН (создаётся ОДИН раз) =====================

  Future<void> _initTimeline() async {
    if (!mounted) return;
    try {
      if (widget.room.getState(EventTypes.RoomCreate) == null) {
        await widget.room.postLoad();
      }

      // Создаём таймлайн ОДИН раз
      final timeline = await widget.room.getTimeline();
      _timeline = timeline;

      // Загружаем старые сообщения с сервера
      await _requestMoreHistory();

      if (mounted) {
        setState(() { _isLoading = false; });
        _scrollToBottom();
      }

      // Слушаем прокрутку вверх для подгрузки истории
      _scrollController.addListener(_onScroll);
    } catch (e) {
      debugPrint("Timeline init error: $e");
      if (mounted) setState(() { _isLoading = false; });
    }
  }

  /// Подгрузка старых сообщений
  Future<void> _requestMoreHistory() async {
    if (_timeline == null || !_canLoadMoreHistory) return;
    try {
      final countBefore = _timeline!.events.length;
      await _timeline!.requestHistory();
      final countAfter = _timeline!.events.length;
      // Если количество событий не изменилось — история кончилась
      if (countAfter == countBefore) {
        _canLoadMoreHistory = false;
      }
    } catch (e) {
      debugPrint("History request error: $e");
      // Если метод не поддерживается — не критично
    }
  }

  /// При прокрутке вверх — подгрузить ещё историю
  void _onScroll() {
    if (_scrollController.hasClients &&
        _scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 100 &&
        !_isLoadingHistory &&
        _canLoadMoreHistory &&
        _timeline != null) {
      _loadMoreHistory();
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

  // ===================== ОТПРАВКА ТЕКСТА =====================

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() { _isSending = true; });
    _controller.clear();

    try {
      await widget.room.sendTextEvent(text);
      // Таймлайн обновится автоматически через room.onUpdate
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка отправки: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() { _isSending = false; });
    }
  }

  // ===================== ОТПРАВКА КАРТИНКИ =====================

  Future<void> _sendImage() async {
    try {
      final picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );
      if (image == null) return;

      setState(() { _isSending = true; });

      final bytes = await image.readAsBytes();
      final matrixFile = MatrixImageFile(
        bytes: bytes,
        name: image.name,
        mimeType: image.mimeType,
      );

      await widget.room.sendFileEvent(matrixFile);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка отправки картинки: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() { _isSending = false; });
    }
  }

  // ===================== ОТПРАВКА ФАЙЛА =====================

  Future<void> _sendFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Не удалось прочитать файл"),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      setState(() { _isSending = true; });

      final matrixFile = MatrixFile(
        bytes: file.bytes!,
        name: file.name,
        mimeType: _getMimeType(file.name, file.extension),
      );

      await widget.room.sendFileEvent(matrixFile);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка отправки файла: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() { _isSending = false; });
    }
  }

  String? _getMimeType(String name, String? extension) {
    final ext = (extension ?? name.split('.').last).toLowerCase();
    const mimeMap = {
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'txt': 'text/plain',
      'zip': 'application/zip',
      'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',
    };
    return mimeMap[ext];
  }

  // ===================== МЕНЮ ВЛОЖЕНИЙ =====================

  void _showAttachmentMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  "Прикрепить",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _attachOption(
                      icon: Icons.photo_library,
                      label: "Галерея",
                      color: Colors.purple,
                      onTap: () {
                        Navigator.pop(context);
                        _sendImage();
                      },
                    ),
                    _attachOption(
                      icon: Icons.camera_alt,
                      label: "Камера",
                      color: Colors.orange,
                      onTap: () async {
                        Navigator.pop(context);
                        try {
                          final picker = ImagePicker();
                          final XFile? photo = await picker.pickImage(
                            source: ImageSource.camera,
                            maxWidth: 1920,
                            maxHeight: 1920,
                            imageQuality: 85,
                          );
                          if (photo == null) return;

                          setState(() { _isSending = true; });

                          final bytes = await photo.readAsBytes();
                          final matrixFile = MatrixImageFile(
                            bytes: bytes,
                            name: photo.name,
                            mimeType: photo.mimeType,
                          );

                          await widget.room.sendFileEvent(matrixFile);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text("Ошибка: $e"), backgroundColor: Colors.red),
                            );
                          }
                        } finally {
                          if (mounted) setState(() { _isSending = false; });
                        }
                      },
                    ),
                    _attachOption(
                      icon: Icons.insert_drive_file,
                      label: "Файл",
                      color: Colors.blue,
                      onTap: () {
                        Navigator.pop(context);
                        _sendFile();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _attachOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  // ===================== ФОРМАТИРОВАНИЕ =====================

  String _formatMsgTime(DateTime date) {
    return "${date.hour}:${date.minute.toString().padLeft(2, '0')}";
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDate = DateTime(date.year, date.month, date.day);

    if (msgDate == today) return "Сегодня";
    if (msgDate == today.subtract(const Duration(days: 1))) return "Вчера";
    return "${date.day}.${date.month.toString().padLeft(2, '0')}.${date.year}";
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return "$bytes Б";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} КБ";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ";
  }

  IconData _fileIcon(String? mimeType) {
    if (mimeType == null) return Icons.insert_drive_file;
    if (mimeType.startsWith('application/pdf')) return Icons.picture_as_pdf;
    if (mimeType.startsWith('audio/')) return Icons.audio_file;
    if (mimeType.startsWith('video/')) return Icons.video_file;
    if (mimeType.startsWith('text/')) return Icons.description;
    if (mimeType.contains('zip') || mimeType.contains('rar')) return Icons.folder_zip;
    return Icons.insert_drive_file;
  }

  // ===================== ВИДЖЕТ СООБЩЕНИЯ =====================

  Widget _buildMessageContent(Event event, bool isMe) {
    final msgType = event.messageType;

    // --- Картинка ---
    if (msgType == MessageTypes.Image) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _buildImageWidget(event),
          ),
          if (event.body != null && event.body!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                event.body ?? "",
                style: TextStyle(
                  color: isMe ? Colors.white : Colors.black87,
                  fontSize: 14,
                ),
              ),
            ),
        ],
      );
    }

    // --- Видео ---
    if (msgType == MessageTypes.Video) {
      return _buildFileCard(event, isMe, Icons.video_file, Colors.red);
    }

    // --- Аудио ---
    if (msgType == MessageTypes.Audio) {
      return _buildFileCard(event, isMe, Icons.audio_file, Colors.orange);
    }

    // --- Файл ---
    if (msgType == MessageTypes.File) {
      return _buildFileCard(event, isMe, _fileIcon(event.attachmentMimetype), Colors.blue);
    }

    // --- Обычный текст ---
    return Text(
      event.body ?? "",
      style: TextStyle(
        color: isMe ? Colors.white : Colors.black87,
        fontSize: 16,
      ),
    );
  }

  // ===================== ОТОБРАЖЕНИЕ КАРТИНОК =====================

  /// Загрузка картинки — ТОЛЬКО через SDK (downloadAndDecryptAttachment)
  /// Image.network не работает на Android с сертификатами Conduit
  Widget _buildImageWidget(Event event) {
    final eventId = event.eventId;
    final mxcUrl = event.attachmentMxcUrl;

    // Нет mxc URL — сразу ошибка
    if (mxcUrl == null) {
      debugPrint("[IMAGE] No mxc URL for event $eventId");
      return _imageErrorWidget(event, "Нет URL");
    }

    // Проверяем кэш байтов
    if (_imageCache.containsKey(eventId)) {
      return _imageFromBytes(_imageCache[eventId]!, event);
    }

    // Запускаем загрузку через SDK (только один раз на событие)
    _imageLoadFutures.putIfAbsent(eventId, () => _loadImageBytes(event));

    return FutureBuilder<MatrixFile?>(
      future: _imageLoadFutures[eventId],
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _imageLoadingWidget();
        }

        if (snapshot.hasData && snapshot.data != null) {
          final imageData = snapshot.data!.bytes;
          if (imageData.isNotEmpty) {
            // Сохраняем в кэш
            _imageCache[eventId] = imageData;
            return _imageFromBytes(imageData, event);
          }
          debugPrint("[IMAGE] Empty bytes for event $eventId");
        }

        if (snapshot.hasError) {
          debugPrint("[IMAGE] FutureBuilder error for $eventId: ${snapshot.error}");
        }

        // Основной метод не сработал — пробуем прямой HTTP запрос
        return _buildImageFallbackHttp(event, eventId, mxcUrl);
      },
    );
  }

  /// Основной метод загрузки — через SDK
  Future<MatrixFile?> _loadImageBytes(Event event) async {
    try {
      debugPrint("[IMAGE] Downloading via SDK: ${event.attachmentMxcUrl}");
      final file = await event.downloadAndDecryptAttachment();
      debugPrint("[IMAGE] SDK download OK: ${file.bytes.length} bytes, name: ${file.name}");
      return file;
    } catch (e) {
      debugPrint("[IMAGE] SDK download failed: $e");
      return null;
    }
  }

  /// Фоллбэк — прямой HTTP запрос с авторизацией
  Widget _buildImageFallbackHttp(Event event, String eventId, Uri mxcUrl) {
    final homeserver = widget.matrixService.client.homeserver;
    final accessToken = widget.matrixService.client.accessToken;

    if (homeserver == null || accessToken == null) {
      return _imageErrorWidget(event, "Нет подключения");
    }

    final serverName = mxcUrl.host;
    final mediaId = mxcUrl.pathSegments.join('/');

    // Пробуем v3, потом v1
    final downloadUrls = [
      '${homeserver.scheme}://${homeserver.host}/_matrix/media/v3/download/$serverName/$mediaId',
      '${homeserver.scheme}://${homeserver.host}/_matrix/media/v1/download/$serverName/$mediaId',
    ];

    return _tryHttpDownload(event, eventId, downloadUrls, accessToken, 0);
  }

  /// Попытка HTTP скачивания по списку URL
  Widget _tryHttpDownload(Event event, String eventId, List<String> urls, String accessToken, int urlIndex) {
    if (urlIndex >= urls.length) {
      return _imageErrorWidget(event, "Не удалось загрузить");
    }

    return FutureBuilder<Uint8List?>(
      future: _httpDownloadImage(urls[urlIndex], accessToken, eventId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _imageLoadingWidget();
        }
        if (snapshot.hasData && snapshot.data != null && snapshot.data!.isNotEmpty) {
          _imageCache[eventId] = snapshot.data!;
          return _imageFromBytes(snapshot.data!, event);
        }
        // Пробуем следующий URL
        return _tryHttpDownload(event, eventId, urls, accessToken, urlIndex + 1);
      },
    );
  }

  /// Прямой HTTP запрос для скачивания медиа
  Future<Uint8List?> _httpDownloadImage(String url, String accessToken, String eventId) async {
    try {
      debugPrint("[IMAGE] HTTP download attempt: $url");
      final httpClient = HttpClient();
      try {
        // Принимаем любой сертификат (для самоподписанных)
        httpClient.badCertificateCallback = (cert, host, port) => true;

        final request = await httpClient.getUrl(Uri.parse(url));
        request.headers.set('Authorization', 'Bearer $accessToken');
        final response = await request.close();

        if (response.statusCode == 200) {
          final bytes = await response.fold<BytesBuilder>(
            BytesBuilder(),
            (b, d) => b..add(d),
          );
          debugPrint("[IMAGE] HTTP download OK: ${bytes.length} bytes");
          return bytes.toBytes();
        } else {
          debugPrint("[IMAGE] HTTP ${response.statusCode} for $url");
          return null;
        }
      } finally {
        httpClient.close();
      }
    } catch (e) {
      debugPrint("[IMAGE] HTTP download error: $e");
      return null;
    }
  }

  /// Виджет картинки из байтов
  Widget _imageFromBytes(Uint8List bytes, Event event) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: min(MediaQuery.of(context).size.width * 0.65, 300),
        maxHeight: 300,
      ),
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        errorBuilder: (_, error, ___) {
          debugPrint("[IMAGE] Image.memory decode error: $error");
          return _imageErrorWidget(event, "Ошибка декодирования");
        },
      ),
    );
  }

  /// Виджет загрузки картинки
  Widget _imageLoadingWidget() {
    return Container(
      width: 200,
      height: 150,
      color: Colors.grey[200],
      child: const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  /// Виджет ошибки загрузки картинки
  Widget _imageErrorWidget(Event event, [String? reason]) {
    return Container(
      width: 200,
      height: 80,
      padding: const EdgeInsets.all(8),
      color: Colors.grey[200],
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.image_not_supported, color: Colors.grey, size: 20),
          const SizedBox(height: 2),
          Text(
            reason ?? event.body ?? "Изображение",
            style: const TextStyle(color: Colors.grey, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ===================== КАРТОЧКА ФАЙЛА =====================

  Widget _buildFileCard(Event event, bool isMe, IconData icon, Color iconColor) {
    final fileInfo = event.content['info'] as Map<String, dynamic>?;
    final fileSize = fileInfo?['size'] as int?;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isMe ? Colors.indigo[300] : Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: isMe ? Colors.white : iconColor, size: 32),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.body ?? "Файл",
                  style: TextStyle(
                    color: isMe ? Colors.white : Colors.black87,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (fileSize != null)
                  Text(
                    _formatFileSize(fileSize),
                    style: TextStyle(
                      color: isMe ? Colors.white70 : Colors.grey[600],
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(
              Icons.download,
              color: isMe ? Colors.white : Colors.indigo,
              size: 20,
            ),
            onPressed: () async {
              try {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Скачивание...")),
                );
                final file = await event.downloadAndDecryptAttachment();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Скачано: ${file.name} (${_formatFileSize(file.bytes.length)})")),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Ошибка скачивания: $e")),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }

  // ===================== ПОСТРОЕНИЕ UI =====================

  @override
  Widget build(BuildContext context) {
    final client = widget.matrixService.client;
    final events = _timeline?.events ?? [];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.room.displayname),
      ),
      body: Column(
        children: [
          // Сообщения
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : events.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.chat, size: 48, color: Colors.grey[400]),
                            const SizedBox(height: 8),
                            const Text(
                              "Начните разговор!",
                              style: TextStyle(color: Colors.grey, fontSize: 16),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(10),
                        reverse: true,
                        itemCount: events.length + (_canLoadMoreHistory ? 1 : 0),
                        itemBuilder: (context, index) {
                          // Индикатор подгрузки истории вверху
                          if (index == events.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            );
                          }

                          final event = events[index];
                          final isMe = event.senderId == client.userID;

                          if (event.type != EventTypes.Message) return const SizedBox.shrink();

                          final showDateHeader = index == events.length - 1 ||
                              events[index + 1].originServerTs.day != event.originServerTs.day;

                          final isMedia = event.messageType == MessageTypes.Image ||
                              event.messageType == MessageTypes.Video;

                          return Column(
                            children: [
                              if (showDateHeader)
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.grey[200],
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      _formatDate(event.originServerTs),
                                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                    ),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 4),
                                child: Row(
                                  mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (!isMe)
                                      Padding(
                                        padding: const EdgeInsets.only(right: 8),
                                        child: CircleAvatar(
                                          radius: 14,
                                          backgroundColor: Colors.grey[300],
                                          child: Text(
                                            event.senderId?.localpart?[0].toUpperCase() ?? "?",
                                            style: const TextStyle(fontSize: 12),
                                          ),
                                        ),
                                      ),
                                    Flexible(
                                      child: Container(
                                        constraints: BoxConstraints(
                                          maxWidth: MediaQuery.of(context).size.width * 0.75,
                                        ),
                                        padding: isMedia
                                            ? const EdgeInsets.all(4)
                                            : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        decoration: BoxDecoration(
                                          color: isMe ? Colors.indigo[400] : Colors.grey[200],
                                          borderRadius: BorderRadius.only(
                                            topLeft: const Radius.circular(16),
                                            topRight: const Radius.circular(16),
                                            bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(0),
                                            bottomRight: isMe ? const Radius.circular(0) : const Radius.circular(16),
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            _buildMessageContent(event, isMe),
                                            const SizedBox(height: 4),
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  _formatMsgTime(event.originServerTs),
                                                  style: TextStyle(
                                                    color: isMe ? Colors.white70 : Colors.grey[500],
                                                    fontSize: 10,
                                                  ),
                                                ),
                                                if (isMe && event.status != EventStatus.synced) ...[
                                                  const SizedBox(width: 4),
                                                  Icon(
                                                    event.status == EventStatus.error
                                                        ? Icons.error_outline
                                                        : Icons.access_time,
                                                    size: 12,
                                                    color: isMe ? Colors.white70 : Colors.grey,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    if (isMe) const SizedBox(width: 8),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
          ),

          // Поле ввода
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(color: Colors.grey[300]!, blurRadius: 4, offset: const Offset(0, -1)),
              ],
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file, color: Colors.indigo),
                  onPressed: _isSending ? null : _showAttachmentMenu,
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: "Сообщение...",
                        border: InputBorder.none,
                      ),
                      minLines: 1,
                      maxLines: 5,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: Colors.indigo,
                  child: _isSending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : IconButton(
                          icon: const Icon(Icons.send, color: Colors.white, size: 20),
                          onPressed: _sendMessage,
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
