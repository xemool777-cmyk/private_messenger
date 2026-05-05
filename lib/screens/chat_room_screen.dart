import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../services/matrix_service.dart';
import '../services/notification_service.dart';
import '../services/call_service.dart';
import '../screens/call_screen.dart';
import '../widgets/audio_player_widget.dart';
import '../widgets/e2ee_info_dialog.dart';

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
  StreamSubscription? _keyReceivedSub;
  bool _canLoadMoreHistory = true;

  // Кэш загруженных картинок (eventId → байты)
  final Map<String, Uint8List> _imageCache = {};
  // Кэш Future чтобы не дублировать загрузки
  final Map<String, Future<MatrixFile?>> _imageLoadFutures = {};
  // Кэш загруженных аудио (eventId → байты)
  final Map<String, Uint8List> _audioCache = {};
  final Map<String, Future<Uint8List?>> _audioLoadFutures = {};

  // Запись голосовых сообщений
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  Duration _recordingDuration = Duration.zero;
  Timer? _recordingTimer;
  String? _recordingPath;

  // Звонки
  CallService? _callService;

  @override
  void initState() {
    super.initState();
    // Помечаем что мы в этом чате (чтобы не показывать уведомление)
    widget.matrixService.currentRoomId = widget.room.id;
    // Убираем уведомление для этой комнаты
    NotificationService.instance.cancelNotification(widget.room.id);

    _initTimeline();
    _initCallService();

    // Слушаем обновления комнаты — просто обновляем UI, НЕ пересоздаём таймлайн!
    _roomUpdateSub = widget.room.onUpdate.stream.listen((_) {
      if (mounted) setState(() {});
    });

    // Слушаем получение ключей расшифровки — обновляем UI когда приходят ключи
    _keyReceivedSub = widget.room.onSessionKeyReceived.stream.listen((_) {
      debugPrint('[E2EE] Session key received, updating UI');
      if (mounted) setState(() {});
    });


  }

  void _initCallService() {
    _callService = CallService(widget.matrixService.client);
    _callService!.onIncomingCall = () {
      if (!mounted) return;
      final session = _callService!.activeCall;
      if (session != null) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CallScreen(
              callSession: session,
              callService: _callService!,
            ),
          ),
        );
      }
    };
  }

  @override
  void dispose() {
    // Помечаем что мы вышли из чата
    widget.matrixService.currentRoomId = null;
    _roomUpdateSub?.cancel();
    _keyReceivedSub?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    _callService?.dispose();
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

      // Если комната зашифрована — запрашиваем ключи для нерасшифрованных событий
      final isEncrypted = widget.room.getState('m.room.encryption') != null;
      if (isEncrypted && _timeline != null) {
        final undecrypted = _timeline!.events.where(
          (e) => e.type == EventTypes.Encrypted || e.messageType == MessageTypes.BadEncrypted
        ).length;
        if (undecrypted > 0) {
          debugPrint('[E2EE] $undecrypted undecrypted events, requesting keys...');
          try {
            _timeline!.requestKeys();
            debugPrint('[E2EE] Key request sent');
            if (mounted) setState(() {});
          } catch (e) {
            debugPrint('[E2EE] Key request failed: $e');
          }
        }
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
      if (countAfter == countBefore) {
        _canLoadMoreHistory = false;
      }
    } catch (e) {
      debugPrint("History request error: $e");
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

  /// Проверяем есть ли нерасшифрованные события в таймлайне
  bool _hasUndecryptedEvents() {
    if (_timeline == null) return false;
    return _timeline!.events.any(
      (e) => e.type == EventTypes.Encrypted || e.messageType == MessageTypes.BadEncrypted
    );
  }

  // ===================== ОТПРАВКА ТЕКСТА =====================

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() { _isSending = true; });
    _controller.clear();

    try {
      await widget.room.sendTextEvent(text);
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

  // ===================== ГОЛОСОВЫЕ СООБЩЕНИЯ =====================

  Future<void> _startRecording() async {
    try {
      // Проверяем разрешение на микрофон
      if (await _audioRecorder.hasPermission()) {
        // record v5: start() требует path и возвращает Future<void>
        // На веб path игнорируется, но параметр обязателен
        final audioPath = kIsWeb
            ? ''
            : p.join(
                (await getTemporaryDirectory()).path,
                'recording_${DateTime.now().millisecondsSinceEpoch}.opus',
              );

        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.opus,
            bitRate: 64000,
            sampleRate: 48000,
            numChannels: 1,
          ),
          path: audioPath,
        );

        setState(() {
          _isRecording = true;
          _recordingDuration = Duration.zero;
          _recordingPath = audioPath;
        });

        // Таймер для отображения длительности записи
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) {
            setState(() {
              _recordingDuration += const Duration(seconds: 1);
            });
          }
        });
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Нет доступа к микрофону"),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[AUDIO] Recording start error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка записи: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _stopAndSendRecording() async {
    _recordingTimer?.cancel();
    
    try {
      final path = await _audioRecorder.stop();
      if (path == null) {
        setState(() { _isRecording = false; });
        return;
      }

      setState(() { _isSending = true; _isRecording = false; });

      // Читаем записанный файл
      final file = http.Client();
      // Для отправки используем MatrixAudioFile
      // На веб path = URL blob, на нативе — путь к файлу
      // Используем универсальный способ через MatrixFile
      final bytes = await _readRecordingBytes(path);
      if (bytes == null || bytes.isEmpty) {
        if (mounted) setState(() { _isSending = false; });
        return;
      }

      final matrixFile = MatrixAudioFile(
        bytes: bytes,
        name: 'voice_message.ogg',
        mimeType: 'audio/ogg',
      );

      await widget.room.sendFileEvent(matrixFile);
      debugPrint('[AUDIO] Voice message sent (${bytes.length} bytes)');
    } catch (e) {
      debugPrint('[AUDIO] Send voice error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка отправки голосового: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() { _isSending = false; });
    }
  }

  void _cancelRecording() {
    _recordingTimer?.cancel();
    _audioRecorder.stop(); // Отменяем запись без отправки
    setState(() {
      _isRecording = false;
      _recordingDuration = Duration.zero;
    });
  }

  /// Чтение байтов записи (разные реализации для web/native)
  Future<Uint8List?> _readRecordingBytes(String path) async {
    try {
      // На веб record возвращает blob URL, используем XFile
      // На нативе — путь к файлу
      final xFile = XFile(path);
      final bytes = await xFile.readAsBytes();
      return Uint8List.fromList(bytes);
    } catch (e) {
      debugPrint('[AUDIO] Read bytes error: $e');
      return null;
    }
  }

  // ===================== ВИДЕОЗВОНКИ =====================

  Future<void> _startVideoCall() async {
    if (_callService == null) return;
    
    try {
      final session = await _callService!.startCall(
        widget.room.id,
        video: true,
      );
      
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CallScreen(
              callSession: session,
              callService: _callService!,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[CALL] Start call error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка звонка: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _startAudioCall() async {
    if (_callService == null) return;
    
    try {
      final session = await _callService!.startCall(
        widget.room.id,
        video: false,
      );
      
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CallScreen(
              callSession: session,
              callService: _callService!,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('[CALL] Start audio call error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка звонка: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ===================== E2EE ИНФО =====================

  void _showE2EEInfo() {
    showDialog(
      context: context,
      builder: (_) => E2EEInfoDialog(
        matrixService: widget.matrixService,
        room: widget.room,
      ),
    );
  }

  // ===================== УТИЛИТЫ =====================

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
      'ogg': 'audio/ogg',
      'oga': 'audio/ogg',
      'opus': 'audio/opus',
      'wav': 'audio/wav',
      'm4a': 'audio/mp4',
      'webm': 'audio/webm',
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
                const SizedBox(height: 12),
                // Вторая строка — звонки
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _attachOption(
                      icon: Icons.videocam,
                      label: "Видеозвонок",
                      color: Colors.teal,
                      onTap: () {
                        Navigator.pop(context);
                        _startVideoCall();
                      },
                    ),
                    _attachOption(
                      icon: Icons.phone,
                      label: "Аудиозвонок",
                      color: Colors.green,
                      onTap: () {
                        Navigator.pop(context);
                        _startAudioCall();
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

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return '$minutes:$seconds';
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

    // --- Нерасшифрованное сообщение ---
    if (msgType == MessageTypes.BadEncrypted || event.type == EventTypes.Encrypted) {
      final canRequest = event.content['can_request_session'] == true;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 16, color: isMe ? Colors.white70 : Colors.orange[700]),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  "Не удалось расшифровать",
                  style: TextStyle(
                    color: isMe ? Colors.white70 : Colors.orange[700],
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            canRequest
                ? "Ключи запрошены у других устройств. Подождите..."
                : "Войдите с устройства, где есть ключи расшифровки",
            style: TextStyle(
              color: isMe ? Colors.white54 : Colors.grey[500],
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 6),
          // Кнопка перезапроса ключей
          if (canRequest)
            OutlinedButton.icon(
              onPressed: () {
                try {
                  event.requestKey();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("Ключи запрошены повторно"),
                      backgroundColor: Colors.blue,
                    ),
                  );
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text("Ошибка: $e"),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              icon: Icon(Icons.refresh, size: 14, color: isMe ? Colors.white70 : Colors.orange),
              label: Text(
                "Запросить ключи",
                style: TextStyle(color: isMe ? Colors.white70 : Colors.orange, fontSize: 12),
              ),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                minimumSize: Size.zero,
              ),
            ),
        ],
      );
    }

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

    // --- Аудио (инлайн плеер) ---
    if (msgType == MessageTypes.Audio) {
      return _buildAudioMessage(event, isMe);
    }

    // --- Видео ---
    if (msgType == MessageTypes.Video) {
      return _buildVideoMessage(event, isMe);
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

  // ===================== АУДИО СООБЩЕНИЕ =====================

  Widget _buildAudioMessage(Event event, bool isMe) {
    final eventId = event.eventId;
    final mxcUrl = event.attachmentMxcUrl;
    final fileInfo = event.content['info'] as Map<String, dynamic>?;
    final durationMs = fileInfo?['duration'] as int?;

    // Если есть кэш — показываем плеер
    if (_audioCache.containsKey(eventId)) {
      return AudioPlayerWidget(
        audioBytes: _audioCache[eventId],
        duration: durationMs != null ? Duration(milliseconds: durationMs) : null,
        isMe: isMe,
      );
    }

    // Если нет mxc — показываем файл-карточку
    if (mxcUrl == null) {
      return _buildFileCard(event, isMe, Icons.audio_file, Colors.orange);
    }

    // Загружаем аудио
    _audioLoadFutures.putIfAbsent(eventId, () => _loadAudioBytes(event));

    return FutureBuilder<Uint8List?>(
      future: _audioLoadFutures[eventId],
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isMe ? Colors.indigo[300] : Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: isMe ? Colors.white : Colors.indigo,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  "Загрузка аудио...",
                  style: TextStyle(
                    color: isMe ? Colors.white70 : Colors.grey[600],
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          );
        }

        if (snapshot.hasData && snapshot.data != null && snapshot.data!.isNotEmpty) {
          _audioCache[eventId] = snapshot.data!;
          return AudioPlayerWidget(
            audioBytes: snapshot.data,
            duration: durationMs != null ? Duration(milliseconds: durationMs) : null,
            isMe: isMe,
          );
        }

        // Фоллбэк — файл-карточка с кнопкой скачивания
        return _buildFileCard(event, isMe, Icons.audio_file, Colors.orange);
      },
    );
  }

  Future<Uint8List?> _loadAudioBytes(Event event) async {
    // Метод 1: MSC3916 authenticated download
    try {
      final bytes = await _authenticatedMediaDownload(event);
      if (bytes != null) return bytes;
    } catch (_) {}

    // Метод 2: SDK downloadAndDecryptAttachment
    try {
      final file = await event.downloadAndDecryptAttachment();
      return file.bytes;
    } catch (_) {}

    return null;
  }

  // ===================== ВИДЕО СООБЩЕНИЕ =====================

  Widget _buildVideoMessage(Event event, bool isMe) {
    final fileInfo = event.content['info'] as Map<String, dynamic>?;
    final durationMs = fileInfo?['duration'] as int?;
    final fileSize = fileInfo?['size'] as int?;
    final thumbnailInfo = fileInfo?['thumbnail_info'] as Map<String, dynamic>?;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: isMe ? Colors.indigo[300] : Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Видео-превью с иконкой play
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 200,
                height: 120,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Center(
                  child: Icon(Icons.videocam, color: Colors.white54, size: 40),
                ),
              ),
              // Кнопка play
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 28),
              ),
              // Длительность
              if (durationMs != null)
                Positioned(
                  bottom: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _formatDuration(Duration(milliseconds: durationMs)),
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.video_file, color: isMe ? Colors.white : Colors.red, size: 20),
              const SizedBox(width: 6),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.body ?? "Видео",
                      style: TextStyle(
                        color: isMe ? Colors.white : Colors.black87,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (fileSize != null)
                      Text(
                        _formatFileSize(fileSize),
                        style: TextStyle(
                          color: isMe ? Colors.white70 : Colors.grey[600],
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: Icon(
                  Icons.download,
                  color: isMe ? Colors.white : Colors.indigo,
                  size: 18,
                ),
                onPressed: () async {
                  try {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Скачивание видео...")),
                    );
                    Uint8List? fileBytes;
                    final mxcUrl = event.attachmentMxcUrl;
                    if (mxcUrl != null) {
                      final bytes = await _authenticatedMediaDownload(event);
                      if (bytes != null) fileBytes = bytes;
                    }
                    fileBytes ??= (await event.downloadAndDecryptAttachment()).bytes;
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Скачано: ${_formatFileSize(fileBytes.length)}")),
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
              ),
            ],
          ),
        ],
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
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) return true;
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) return true;
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) return true;
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

    if (_imageCache.containsKey(eventId)) {
      return _imageFromBytes(_imageCache[eventId]!, event);
    }

    _imageLoadFutures.putIfAbsent(eventId, () => _loadImageAllMethods(event));

    return FutureBuilder<Uint8List?>(
      future: _imageLoadFutures[eventId]!.then((file) => file?.bytes),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _imageLoadingWidget();
        }

        if (snapshot.hasData && snapshot.data != null && snapshot.data!.isNotEmpty) {
          final bytes = snapshot.data!;

          if (_looksLikeImage(bytes)) {
            _imageCache[eventId] = bytes;
            return _imageFromBytes(bytes, event);
          } else {
            return _imageErrorWidget(event, "Не картинка (${bytes.length} байт)");
          }
        }

        return _imageErrorWidget(event, "Не удалось загрузить");
      },
    );
  }

  /// Загрузка картинки — пробуем методы по очереди
  Future<MatrixFile?> _loadImageAllMethods(Event event) async {
    final isEncrypted = _isEncryptedMedia(event);
    debugPrint("[IMAGE] Event ${event.eventId}, encrypted=$isEncrypted, mxc=${event.attachmentMxcUrl}");

    // Метод 1: MSC3916
    try {
      final bytes = await _authenticatedMediaDownload(event);
      if (bytes != null && _looksLikeImage(bytes)) {
        return MatrixFile(bytes: bytes, name: event.body ?? 'image');
      }
    } catch (_) {}

    // Метод 2: SDK downloadAndDecryptAttachment
    try {
      final file = await event.downloadAndDecryptAttachment();
      if (_looksLikeImage(file.bytes)) {
        return file;
      }
    } catch (_) {}

    // Метод 3: Legacy
    try {
      final bytes = await _legacyMediaDownload(event);
      if (bytes != null && _looksLikeImage(bytes)) {
        return MatrixFile(bytes: bytes, name: event.body ?? 'image');
      }
    } catch (_) {}

    return null;
  }

  /// MSC3916 Authenticated Media Download
  Future<Uint8List?> _authenticatedMediaDownload(Event event) async {
    final mxcUrl = event.attachmentMxcUrl;
    final homeserver = widget.matrixService.client.homeserver;
    final accessToken = widget.matrixService.client.accessToken;
    if (mxcUrl == null || homeserver == null || accessToken == null) return null;

    final serverName = mxcUrl.host;
    final mediaId = mxcUrl.pathSegments.join('/');

    final url = '${homeserver.scheme}://${homeserver.host}/_matrix/client/v1/media/download/$serverName/$mediaId';

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (response.statusCode == 200) {
        return Uint8List.fromList(response.bodyBytes);
      }
    } catch (_) {}

    return null;
  }

  /// Фоллбэк: старый media endpoint
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
        final response = await http.get(
          Uri.parse(url),
          headers: {'Authorization': 'Bearer $accessToken'},
        );

        if (response.statusCode == 200) {
          return Uint8List.fromList(response.bodyBytes);
        }
      } catch (_) {}
    }
    return null;
  }

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
          return _imageErrorWidget(event, "Ошибка декодирования");
        },
      ),
    );
  }

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
    final isEncrypted = widget.room.getState('m.room.encryption') != null;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Flexible(child: Text(widget.room.displayname)),
            if (isEncrypted) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _showE2EEInfo,
                child: Icon(Icons.lock, size: 16, color: Colors.green[200]),
              ),
            ],
          ],
        ),
        actions: [
          // Кнопка видеозвонка
          IconButton(
            icon: const Icon(Icons.videocam),
            onPressed: _startVideoCall,
            tooltip: "Видеозвонок",
          ),
          // Кнопка аудиозвонка
          IconButton(
            icon: const Icon(Icons.phone),
            onPressed: _startAudioCall,
            tooltip: "Аудиозвонок",
          ),
          // E2EE инфо
          if (isEncrypted)
            IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: _showE2EEInfo,
              tooltip: "Информация о шифровании",
            ),
        ],
      ),
      body: Column(
        children: [
          // Предупреждение если комната не зашифрована
          if (!isEncrypted)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.orange[100],
              child: Row(
                children: [
                  Icon(Icons.lock_open, size: 18, color: Colors.orange[800]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Сквозное шифрование не включено. Ваши сообщения не защищены.",
                      style: TextStyle(color: Colors.orange[900], fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          // Предупреждение о новом устройстве в зашифрованной комнате
          if (isEncrypted && _timeline != null && _hasUndecryptedEvents())
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.amber[100],
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: Colors.amber[800]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Некоторые сообщения не удалось расшифровать. "
                      "Ключи запрошены у ваших других устройств. "
                      "Нажмите 🔒 для подробностей.",
                      style: TextStyle(color: Colors.amber[900], fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
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

                          if (event.type != EventTypes.Message && event.type != EventTypes.Encrypted) return const SizedBox.shrink();

                          final showDateHeader = index == events.length - 1 ||
                              events[index + 1].originServerTs.day != event.originServerTs.day;

                          final isMedia = event.messageType == MessageTypes.Image ||
                              event.messageType == MessageTypes.Video ||
                              event.messageType == MessageTypes.Audio;

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

          // Поле ввода (или интерфейс записи)
          _isRecording ? _buildRecordingUI() : _buildInputUI(),
        ],
      ),
    );
  }

  /// UI записи голосового сообщения
  Widget _buildRecordingUI() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.red[50],
        boxShadow: [
          BoxShadow(color: Colors.grey[300]!, blurRadius: 4, offset: const Offset(0, -1)),
        ],
      ),
      child: Row(
        children: [
          // Пульсирующая точка
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          // Время записи
          Text(
            _formatDuration(_recordingDuration),
            style: TextStyle(
              color: Colors.red[700],
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            "Запись...",
            style: TextStyle(color: Colors.red[400], fontSize: 13),
          ),
          const Spacer(),
          // Кнопка отмены
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red),
            onPressed: _cancelRecording,
            tooltip: "Отменить",
          ),
          // Кнопка отправки
          CircleAvatar(
            backgroundColor: Colors.red,
            child: IconButton(
              icon: const Icon(Icons.send, color: Colors.white, size: 20),
              onPressed: _stopAndSendRecording,
              tooltip: "Отправить",
            ),
          ),
        ],
      ),
    );
  }

  /// UI поля ввода
  Widget _buildInputUI() {
    return Container(
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
          const SizedBox(width: 4),
          // Кнопка микрофона (всегда видна)
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
                    icon: const Icon(Icons.mic, color: Colors.white, size: 22),
                    onPressed: _startRecording,
                    tooltip: "Голосовое сообщение",
                  ),
          ),
          const SizedBox(width: 4),
          // Кнопка отправки (всегда видна)
          CircleAvatar(
            backgroundColor: Colors.indigo,
            child: IconButton(
              icon: const Icon(Icons.send, color: Colors.white, size: 22),
              onPressed: _isSending ? null : _sendMessage,
              tooltip: "Отправить",
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

  Future<Uint8List?> _downloadImage() async {
    if (widget.cachedBytes != null) return widget.cachedBytes!;

    final mxcUrl = widget.event.attachmentMxcUrl;
    final homeserver = widget.matrixService.client.homeserver;
    final accessToken = widget.matrixService.client.accessToken;
    if (mxcUrl == null || homeserver == null || accessToken == null) return null;

    final serverName = mxcUrl.host;
    final mediaId = mxcUrl.pathSegments.join('/');
    final url = '${homeserver.scheme}://${homeserver.host}/_matrix/client/v1/media/download/$serverName/$mediaId';

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode == 200) {
        return Uint8List.fromList(response.bodyBytes);
      }
    } catch (_) {}

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
