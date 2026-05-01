import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../services/matrix_service.dart';
import '../services/notification_service.dart';

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
    // Помечаем что мы в этом чате (чтобы не показывать уведомление)
    widget.matrixService.currentRoomId = widget.room.id;
    // Убираем уведомление для этой комнаты
    NotificationService.instance.cancelNotification(widget.room.id);

    _initTimeline();

    // Слушаем обновления комнаты — просто обновляем UI, НЕ пересоздаём таймлайн!
    _roomUpdateSub = widget.room.onUpdate.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    // Помечаем что мы вышли из чата
    widget.matrixService.currentRoomId = null;
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
          GestureDetector(
            onTap: () => _openFullScreenImage(event),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: _buildImageWidget(event),
            ),
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

  /// Диагностика — первые байты в hex
  String _hexDump(Uint8List bytes, [int maxLen = 16]) {
    final sb = StringBuffer();
    for (int i = 0; i < bytes.length && i < maxLen; i++) {
      sb.write('${bytes[i].toRadixString(16).padLeft(2, '0')} ');
    }
    return sb.toString().trim();
  }

  /// Проверка — похожи ли байты на картинку
  bool _looksLikeImage(Uint8List bytes) {
    if (bytes.length < 4) return false;
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return true;
    // GIF: 47 49 46
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    // WebP: 52 49 46 46 ... 57 45 42 50
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) return true;
    // BMP: 42 4D
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    return false;
  }

  /// Проверка — зашифровано ли медиа в событии
  bool _isEncryptedMedia(Event event) {
    final content = event.content;
    return content.containsKey('file');
  }

  /// Загрузка картинки
  Widget _buildImageWidget(Event event) {
    final eventId = event.eventId;
    final mxcUrl = event.attachmentMxcUrl;

    if (mxcUrl == null) {
      debugPrint("[IMAGE] No mxc URL for event $eventId");
      return _imageErrorWidget(event, "Нет URL");
    }

    // Проверяем кэш
    if (_imageCache.containsKey(eventId)) {
      return _imageFromBytes(_imageCache[eventId]!, event);
    }

    // Запускаем цепочку загрузки (только один раз на событие)
    _imageLoadFutures.putIfAbsent(eventId, () => _loadImageAllMethods(event));

    return FutureBuilder<Uint8List?>(
      future: _imageLoadFutures[eventId]!.then((file) => file?.bytes),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _imageLoadingWidget();
        }

        if (snapshot.hasData && snapshot.data != null && snapshot.data!.isNotEmpty) {
          final bytes = snapshot.data!;
          debugPrint("[IMAGE] Got ${bytes.length} bytes, hex: ${_hexDump(bytes)}");

          if (_looksLikeImage(bytes)) {
            _imageCache[eventId] = bytes;
            return _imageFromBytes(bytes, event);
          } else {
            debugPrint("[IMAGE] Bytes don't look like an image! First hex: ${_hexDump(bytes)}");
            // Если байты не похожи на картинку — показываем диагностику
            return _imageErrorWidget(event, "Не картинка (${bytes.length} байт)");
          }
        }

        debugPrint("[IMAGE] All methods failed for $eventId");
        return _imageErrorWidget(event, "Не удалось загрузить");
      },
    );
  }

  /// Загрузка картинки — пробуем методы по очереди
  /// 
  /// КЛЮЧЕВОЕ: Conduit включил MSC3916 (authenticated media).
  /// Старый endpoint /_matrix/media/v3/download/ возвращает M_NOT_FOUND.
  /// Нужен /_matrix/client/v1/media/download/ с Authorization header!
  Future<MatrixFile?> _loadImageAllMethods(Event event) async {
    final isEncrypted = _isEncryptedMedia(event);
    debugPrint("[IMAGE] Event ${event.eventId}, encrypted=$isEncrypted, mxc=${event.attachmentMxcUrl}");

    // Метод 1: /_matrix/client/v1/media/download/ с Authorization (MSC3916)
    // Это ПРАВИЛЬНЫЙ endpoint для новых версий Conduit!
    try {
      debugPrint("[IMAGE] Method 1: client/v1/media/download (MSC3916)");
      final bytes = await _authenticatedMediaDownload(event);
      if (bytes != null && _looksLikeImage(bytes)) {
        debugPrint("[IMAGE] Method 1 OK: ${bytes.length} bytes ✓");
        return MatrixFile(bytes: bytes, name: event.body ?? 'image');
      } else if (bytes != null) {
        debugPrint("[IMAGE] Method 1: got ${bytes.length} bytes but NOT image, hex: ${_hexDump(bytes)}");
      }
    } catch (e) {
      debugPrint("[IMAGE] Method 1 FAILED: $e");
    }

    // Метод 2: SDK downloadAndDecryptAttachment (для зашифрованных)
    try {
      debugPrint("[IMAGE] Method 2: SDK downloadAndDecryptAttachment");
      final file = await event.downloadAndDecryptAttachment();
      debugPrint("[IMAGE] Method 2 OK: ${file.bytes.length} bytes, hex: ${_hexDump(file.bytes)}");

      if (_looksLikeImage(file.bytes)) {
        debugPrint("[IMAGE] Method 2: bytes look like image ✓");
        return file;
      } else {
        debugPrint("[IMAGE] Method 2: bytes NOT a valid image, trying next method");
      }
    } catch (e) {
      debugPrint("[IMAGE] Method 2 FAILED: $e");
    }

    // Метод 3: Старый media/v3 с токеном в URL (фоллбэк для старых серверов)
    try {
      debugPrint("[IMAGE] Method 3: media/v3 with token in URL");
      final bytes = await _legacyMediaDownload(event);
      if (bytes != null && _looksLikeImage(bytes)) {
        debugPrint("[IMAGE] Method 3 OK: ${bytes.length} bytes ✓");
        return MatrixFile(bytes: bytes, name: event.body ?? 'image');
      } else if (bytes != null) {
        debugPrint("[IMAGE] Method 3: got ${bytes.length} bytes but NOT image, hex: ${_hexDump(bytes)}");
      }
    } catch (e) {
      debugPrint("[IMAGE] Method 3 FAILED: $e");
    }

    debugPrint("[IMAGE] ALL METHODS FAILED for ${event.eventId}");
    return null;
  }

  /// ГЛАВНЫЙ МЕТОД: Authenticated Media Download (MSC3916)
  /// Conduit требует /_matrix/client/v1/media/download/ с Bearer token
  Future<Uint8List?> _authenticatedMediaDownload(Event event) async {
    final mxcUrl = event.attachmentMxcUrl;
    final homeserver = widget.matrixService.client.homeserver;
    final accessToken = widget.matrixService.client.accessToken;
    if (mxcUrl == null || homeserver == null || accessToken == null) return null;

    final serverName = mxcUrl.host;
    final mediaId = mxcUrl.pathSegments.join('/');

    // MSC3916 authenticated media endpoint
    final url = '${homeserver.scheme}://${homeserver.host}/_matrix/client/v1/media/download/$serverName/$mediaId';
    debugPrint("[IMAGE] MSC3916 URL: $url");

    try {
      final httpClient = HttpClient();
      try {
        httpClient.badCertificateCallback = (cert, host, port) => true;
        final request = await httpClient.getUrl(Uri.parse(url));
        request.headers.set('Authorization', 'Bearer $accessToken');
        final response = await request.close();

        if (response.statusCode == 200) {
          final builder = await response.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
          debugPrint("[IMAGE] MSC3916 download OK: ${builder.length} bytes");
          return builder.toBytes();
        } else {
          final body = await response.fold<String>('', (s, d) => s + String.fromCharCodes(d));
          debugPrint("[IMAGE] MSC3916 status ${response.statusCode}: $body");
          return null;
        }
      } finally {
        httpClient.close();
      }
    } catch (e) {
      debugPrint("[IMAGE] MSC3916 error: $e");
      return null;
    }
  }

  /// Фоллбэк: старый media endpoint с токеном в URL
  Future<Uint8List?> _legacyMediaDownload(Event event) async {
    final mxcUrl = event.attachmentMxcUrl;
    final homeserver = widget.matrixService.client.homeserver;
    final accessToken = widget.matrixService.client.accessToken;
    if (mxcUrl == null || homeserver == null || accessToken == null) return null;

    final serverName = mxcUrl.host;
    final mediaId = mxcUrl.pathSegments.join('/');

    final urls = [
      '${homeserver.scheme}://${homeserver.host}/_matrix/media/v3/download/$serverName/$mediaId?access_token=$accessToken',
      '${homeserver.scheme}://${homeserver.host}/_matrix/media/v3/download/$serverName/$mediaId',
    ];

    for (final url in urls) {
      try {
        debugPrint("[IMAGE] Legacy: $url");
        final httpClient = HttpClient();
        try {
          httpClient.badCertificateCallback = (cert, host, port) => true;
          final request = await httpClient.getUrl(Uri.parse(url));
          request.headers.set('Authorization', 'Bearer $accessToken');
          final response = await request.close();

          if (response.statusCode == 200) {
            final builder = await response.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
            debugPrint("[IMAGE] Legacy OK: ${builder.length} bytes");
            return builder.toBytes();
          } else {
            debugPrint("[IMAGE] Legacy status ${response.statusCode}");
          }
        } finally {
          httpClient.close();
        }
      } catch (e) {
        debugPrint("[IMAGE] Legacy error: $e");
      }
    }
    return null;
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

  // ===================== ПОЛНОЭКРАННЫЙ ПРОСМОТР КАРТИНКИ =====================

  void _openFullScreenImage(Event event) {
    final eventId = event.eventId;
    final cachedBytes = _imageCache[eventId];

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullScreenImageView(
          event: event,
          cachedBytes: cachedBytes,
          matrixService: widget.matrixService,
        ),
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
                // Пробуем MSC3916 endpoint, потом SDK
                Uint8List? fileBytes;
                final mxcUrl = event.attachmentMxcUrl;
                if (mxcUrl != null) {
                  final bytes = await _authenticatedMediaDownload(event);
                  if (bytes != null) fileBytes = bytes;
                }
                fileBytes ??= (await event.downloadAndDecryptAttachment()).bytes;
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Скачано: ${event.body ?? 'файл'} (${_formatFileSize(fileBytes.length)})")),
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
        title: Row(
          children: [
            Flexible(child: Text(widget.room.displayname)),
            if (widget.room.getState('m.room.encryption') != null) ...[
              const SizedBox(width: 6),
              Icon(Icons.lock, size: 16, color: Colors.green[200]),
            ],
          ],
        ),
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

// ===================== ПОЛНОЭКРАННЫЙ ПРОСМОТР КАРТИНКИ =====================

class _FullScreenImageView extends StatefulWidget {
  final Event event;
  final Uint8List? cachedBytes;
  final MatrixService matrixService;

  const _FullScreenImageView({
    required this.event,
    this.cachedBytes,
    required this.matrixService,
  });

  @override
  State<_FullScreenImageView> createState() => _FullScreenImageViewState();
}

class _FullScreenImageViewState extends State<_FullScreenImageView> {
  final TransformationController _transformController = TransformationController();

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  /// Скачивание через MSC3916 (как в чате)
  Future<Uint8List?> _downloadImage() async {
    // Если есть кэш — используем
    if (widget.cachedBytes != null) return widget.cachedBytes!;

    final mxcUrl = widget.event.attachmentMxcUrl;
    final homeserver = widget.matrixService.client.homeserver;
    final accessToken = widget.matrixService.client.accessToken;
    if (mxcUrl == null || homeserver == null || accessToken == null) return null;

    final serverName = mxcUrl.host;
    final mediaId = mxcUrl.pathSegments.join('/');

    // MSC3916 endpoint
    final url = '${homeserver.scheme}://${homeserver.host}/_matrix/client/v1/media/download/$serverName/$mediaId';

    try {
      final httpClient = HttpClient();
      try {
        httpClient.badCertificateCallback = (cert, host, port) => true;
        final request = await httpClient.getUrl(Uri.parse(url));
        request.headers.set('Authorization', 'Bearer $accessToken');
        final response = await request.close();

        if (response.statusCode == 200) {
          final builder = await response.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
          return builder.toBytes();
        }
      } finally {
        httpClient.close();
      }
    } catch (_) {}

    // Фоллбэк: SDK
    try {
      final file = await widget.event.downloadAndDecryptAttachment();
      return file.bytes;
    } catch (_) {}

    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.event.body ?? "Изображение",
          style: const TextStyle(fontSize: 14),
        ),
      ),
      body: Center(
        child: FutureBuilder<Uint8List?>(
          future: _downloadImage(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const CircularProgressIndicator(color: Colors.white);
            }

            if (snapshot.hasData && snapshot.data != null && snapshot.data!.isNotEmpty) {
              return InteractiveViewer(
                transformationController: _transformController,
                minScale: 0.5,
                maxScale: 4.0,
                child: Image.memory(
                  snapshot.data!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.broken_image, color: Colors.white54, size: 64),
                      SizedBox(height: 12),
                      Text("Не удалось отобразить", style: TextStyle(color: Colors.white54)),
                    ],
                  ),
                ),
              );
            }

            return const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, color: Colors.white54, size: 64),
                SizedBox(height: 12),
                Text("Не удалось загрузить", style: TextStyle(color: Colors.white54)),
              ],
            );
          },
        ),
      ),
    );
  }
}
