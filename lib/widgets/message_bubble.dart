import 'dart:async';
import 'dart:io';
import 'dart:html' as html;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:video_player/video_player.dart';
import '../services/media_service.dart';
import 'image_gallery.dart';

/// Виджет пузыря сообщения в чате.
///
/// Отображает дату (опционально), аватар отправителя, сам пузырь с контентом,
/// reply-цитату, время и статус доставки.
/// Не использует BuildContext для MediaQuery — screenWidth передаётся параметром.
class MessageBubble extends StatelessWidget {
  final Event event;
  final bool isMe;
  final bool showDateHeader;
  final Event? repliedEvent;
  final String currentUserId;
  final double screenWidth;
  final void Function(Event) onReply;
  final void Function(Event, bool) onLongPress;
  final void Function(Event) onResend;
  final void Function(Event) onRemove;
  final MediaService mediaService;
  final void Function(Event) onOpenImage;
  final Timeline? timeline;
  final bool isSending;

  const MessageBubble({
    super.key,
    required this.event,
    required this.isMe,
    required this.showDateHeader,
    this.repliedEvent,
    required this.currentUserId,
    required this.screenWidth,
    required this.onReply,
    required this.onLongPress,
    required this.onResend,
    required this.onRemove,
    required this.mediaService,
    required this.onOpenImage,
    this.timeline,
    this.isSending = false,
  });

  // ===================== BUILD =====================

  @override
  Widget build(BuildContext context) {
    final isFailed = isMe && event.status == EventStatus.error;
    final isMedia = event.messageType == MessageTypes.Image ||
        event.messageType == MessageTypes.Video ||
        event.messageType == MessageTypes.Audio;

    return Column(
      children: [
        // — Date header —
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

        // — Message row (avatar + bubble) —
        GestureDetector(
          onLongPress: () => onLongPress(event, isMe),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment:
                  isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Аватар собеседника
                if (!isMe)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: CircleAvatar(
                      radius: 14,
                      backgroundColor: Colors.grey[300],
                      child: Text(
                        ((event.senderId?.localpart) ?? '?')[0].toUpperCase(),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ),

                // — Bubble —
                Flexible(
                  child: Container(
                    constraints:
                        BoxConstraints(maxWidth: screenWidth * 0.75),
                    padding: isMedia
                        ? const EdgeInsets.all(4)
                        : const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isFailed
                          ? Colors.red[100]
                          : isMe
                              ? Colors.indigo[400]
                              : Colors.grey[200],
                      border: isFailed
                          ? Border.all(color: Colors.red, width: 1)
                          : null,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: isMe
                            ? const Radius.circular(16)
                            : const Radius.circular(0),
                        bottomRight: isMe
                            ? const Radius.circular(0)
                            : const Radius.circular(16),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Reply quote
                        if (repliedEvent != null)
                          _buildReplyQuote(context, repliedEvent!),

                        // Основной контент
                        _buildMessageContent(context),

                        const SizedBox(height: 4),

                        // Время + статус
                        _buildTimeAndStatus(),
                      ],
                    ),
                  ),
                ),
                if (isMe) const SizedBox(width: 8),
              ],
            ),
          ),
        ),
        // ---- Reactions (P2.6) ----
        _buildReactions(),
      ],
    );
  }

  // ===================== REACTIONS (P2.6) =====================

  Widget _buildReactions() {
    final tl = timeline;
    if (tl == null) return const SizedBox.shrink();
    final reactionEvents = event.aggregatedEvents(tl, RelationshipTypes.reaction);
    if (reactionEvents.isEmpty) return const SizedBox.shrink();

    // Count reactions per emoji key
    final Map<String, int> counts = {};
    for (final e in reactionEvents) {
      final relates = e.content['m.relates_to'];
      final key = (relates is Map<String, Object?>) ? (relates['key'] as String? ?? '') : '';
      if (key.isNotEmpty) {
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }

    return Padding(
      padding: EdgeInsets.only(top: 2, left: isMe ? 0 : 42),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Wrap(
          spacing: 4,
          children: counts.entries.map((entry) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey[300]!, width: 0.5),
              ),
              child: Text(
                '${entry.key} ${entry.value}',
                style: const TextStyle(fontSize: 12),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ===================== MESSAGE CONTENT =====================

  Widget _buildMessageContent(BuildContext context) {
    final msgType = event.messageType;

    // Зашифрованное / нерасшифрованное
    if (msgType == MessageTypes.BadEncrypted ||
        event.type == EventTypes.Encrypted) {
      return _buildEncryptedContent();
    }

    // Изображение
    if (msgType == MessageTypes.Image) {
      return _buildImageContent();
    }

    // Видео
    if (msgType == MessageTypes.Video) {
      return _buildVideoPlayer();
    }

    // Аудио
    if (msgType == MessageTypes.Audio) {
      return _buildAudioPlayer();
    }

    // Файл
    if (msgType == MessageTypes.File) {
      return _buildFileCard(
        context, event, isMe, _fileIcon(event.attachmentMimetype), Colors.blue,
      );
    }

    // Текстовое сообщение по умолчанию
    return Text(
      event.body,
      style: TextStyle(
        color: isMe ? Colors.white : Colors.black87,
        fontSize: 16,
      ),
    );
  }

  // ===================== ENCRYPTED =====================

  Widget _buildEncryptedContent() {
    final canRequest = event.content['can_request_session'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 16,
              color: isMe ? Colors.white70 : Colors.orange[700],
            ),
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
      ],
    );
  }

  // ===================== IMAGE =====================

  Widget _buildImageContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ImageGalleryWidget(
            event: event,
            mediaService: mediaService,
            onTap: onOpenImage,
          ),
        ),
        if (event.body.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              event.body,
              style: TextStyle(
                color: isMe ? Colors.white : Colors.black87,
                fontSize: 14,
              ),
            ),
          ),
      ],
    );
  }

  // ===================== FILE CARD =====================

  Widget _buildFileCard(
    BuildContext context,
    Event event,
    bool isMe,
    IconData icon,
    Color iconColor,
  ) {
    final fileInfo = event.content['info'] is Map<String, dynamic> ? event.content['info'] as Map<String, dynamic> : null;
    final fileSize = fileInfo != null && fileInfo['size'] is int ? fileInfo['size'] as int : null;

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
                  event.body,
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
            onPressed: () => _downloadFile(context, event),
          ),
        ],
      ),
    );
  }

  // ===================== AUDIO PLAYER =====================

  Widget _buildAudioPlayer() {
    return _AudioPlayerWidget(
      key: ValueKey('audio_${event.eventId}'),
      event: event,
      isMe: isMe,
      mediaService: mediaService,
    );
  }

  // ===================== VIDEO PLAYER =====================

  Widget _buildVideoPlayer() {
    return _VideoPlayerWidget(
      event: event,
      isMe: isMe,
      mediaService: mediaService,
    );
  }

  Future<void> _downloadFile(BuildContext context, Event event) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Скачивание..."),
        ),
      );

      Uint8List? fileBytes;
      try {
        fileBytes = (await event.downloadAndDecryptAttachment()).bytes;
      } catch (_) {
        fileBytes = await mediaService.authenticatedMediaDownload(event);
      }
      if (fileBytes == null) return;

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              "Скачано: ${event.body} (${_formatFileSize(fileBytes.length)})",
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка скачивания: $e"),
          ),
        );
      }
    }
  }

  // ===================== REPLY QUOTE =====================

  Widget _buildReplyQuote(BuildContext context, Event repliedEvent) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: (isMe ? Colors.white : Colors.indigo).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(
            color: isMe ? Colors.white70 : Colors.indigo,
            width: 2,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            repliedEvent.senderId?.localpart ?? 'User',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 11,
              color: isMe ? Colors.white70 : Colors.indigo,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            _getReplySnippet(repliedEvent),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: isMe ? Colors.white60 : Colors.grey[700],
            ),
          ),
        ],
      ),
    );
  }

  // ===================== TIME & STATUS =====================

  Widget _buildTimeAndStatus() {
    final isEdited = timeline != null && event.hasAggregatedEvents(timeline!, 'm.replace');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isEdited)
          Text(
            "изменено ",
            style: TextStyle(
              color: isMe ? Colors.white54 : Colors.grey[500],
              fontSize: 10,
              fontStyle: FontStyle.italic,
            ),
          ),
        Text(
          _formatMsgTime(event.originServerTs),
          style: TextStyle(
            color: isMe ? Colors.white70 : Colors.grey[500],
            fontSize: 10,
          ),
        ),
        if (isMe) ...[
          const SizedBox(width: 4),
          _StatusIcon(
            status: event.status,
            isSending: isSending && event.status == EventStatus.sending,
            color: Colors.white70,
          ),
        ],
      ],
    );
  }

  // ===================== FORMATTING =====================

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
    if (bytes < 1024 * 1024) {
      return "${(bytes / 1024).toStringAsFixed(1)} КБ";
    }
    return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ";
  }

  IconData _fileIcon(String? mimeType) {
    if (mimeType == null) return Icons.insert_drive_file;
    if (mimeType.startsWith('application/pdf')) return Icons.picture_as_pdf;
    if (mimeType.startsWith('audio/')) return Icons.audio_file;
    if (mimeType.startsWith('video/')) return Icons.video_file;
    if (mimeType.startsWith('text/')) return Icons.description;
    if (mimeType.contains('zip') || mimeType.contains('rar')) {
      return Icons.folder_zip;
    }
    return Icons.insert_drive_file;
  }

  String _getReplySnippet(Event event) {
    if (event.messageType == MessageTypes.Image) return '\u{1F4F7} Фото';
    if (event.messageType == MessageTypes.Video) return '\u{1F3A5} Видео';
    if (event.messageType == MessageTypes.Audio) return '\u{1F3B5} Аудио';
    if (event.messageType == MessageTypes.File) return '\u{1F4CE} Файл';
    if (event.type == EventTypes.Encrypted ||
        event.messageType == MessageTypes.BadEncrypted) {
      return '\u{1F512} Зашифрованное сообщение';
    }
    return event.body;
  }
}

/// Индикатор статуса сообщения:
/// - спиннер при отправке (isSending=true или status==sending)
/// - 1 галочка = доставлено (sent)
/// - 2 галочки = прочитано (synced)
/// - значок ошибки при ошибке
class _StatusIcon extends StatelessWidget {
  final EventStatus status;
  final bool isSending;
  final Color color;

  const _StatusIcon({required this.status, required this.isSending, required this.color});

  @override
  Widget build(BuildContext context) {
    if (isSending || status == EventStatus.sending) {
      return SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: color,
        ),
      );
    }
    switch (status) {
      case EventStatus.sent:
        return Icon(Icons.done, size: 14, color: color);
      case EventStatus.synced:
        return Icon(Icons.done_all, size: 14, color: color);
      case EventStatus.error:
        return Icon(Icons.error_outline, size: 14, color: color);
      default:
        return const SizedBox.shrink();
    }
  }
}

/// Виджет аудиоплеера для голосовых сообщений.
/// Загружает аудио, показывает play/pause и прогресс.
class _AudioPlayerWidget extends StatefulWidget {
  final Event event;
  final bool isMe;
  final MediaService mediaService;

  const _AudioPlayerWidget({
    super.key,
    required this.event,
    required this.isMe,
    required this.mediaService,
  });

  @override
  State<_AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<_AudioPlayerWidget> {
  // --- Web: html.AudioElement ---
  html.AudioElement? _htmlAudio;
  String? _blobUrl;

  // --- Native: audioplayers AudioPlayer ---
  AudioPlayer? _nativePlayer;

  // --- Состояние ---
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _isInitialized = false;
  bool _isUnsupported = false; // браузер не поддерживает формат
  String? _errorMessage;

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  Timer? _progressTimer;

  // MIME-тип (из метаданных или по расширению)
  String? _actualMimeType;
  // Предзагруженные байты
  Uint8List? _preloadedBytes;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _nativePlayer = AudioPlayer();
      _nativePlayer!.onPlayerStateChanged.listen((state) {
        if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
      });
      _nativePlayer!.onDurationChanged.listen((d) {
        if (mounted) setState(() => _duration = d);
      });
      _nativePlayer!.onPositionChanged.listen((p) {
        if (mounted) setState(() => _position = p);
      });
      _nativePlayer!.onPlayerComplete.listen((_) {
        if (mounted) setState(() => _isPlaying = false);
      });
    }
    _preloadBytes();
  }

  /// Фоновая загрузка: к моменту тапа байты уже готовы (важно для iOS gesture context)
  Future<void> _preloadBytes() async {
    try {
      Uint8List? bytes;
      try {
        bytes = (await widget.event.downloadAndDecryptAttachment()).bytes;
      } catch (_) {
        bytes = await widget.mediaService.authenticatedMediaDownload(widget.event);
      }

      if (!mounted) return;
      if (bytes == null) return;

      _preloadedBytes = bytes;
      _actualMimeType = widget.event.attachmentMimetype.isNotEmpty
          ? widget.event.attachmentMimetype
          : _detectMimeFromName(widget.event.body);

      // Проверяем поддержку формата браузером (только web)
      if (kIsWeb && _actualMimeType!.isNotEmpty) {
        _isUnsupported = _checkUnsupported(_actualMimeType!);
      }

      // Предварительно создаём Blob, чтобы первый play был мгновенным
      if (kIsWeb && bytes.isNotEmpty) {
        _createWebAudio(bytes);
        setState(() {});
      }
    } catch (_) {
      // ошибка предзагрузки — покажем при тапе
    }
  }

  /// Определить MIME по расширению файла
  String _detectMimeFromName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'weba':
      case 'webm':
        return 'audio/webm';
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
      case 'mp4':
        return 'audio/mp4';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'aac':
        return 'audio/aac';
      default:
        return 'audio/webm';
    }
  }

  /// Проверить, поддерживает ли браузер формат
  static bool _checkUnsupported(String mime) {
    final test = html.AudioElement();
    final result = test.canPlayType(mime);
    test.remove();
    return result.isEmpty; // '' значит не поддерживает
  }

  /// Создать web AudioElement из байтов (не запускает play)
  void _createWebAudio(Uint8List bytes) {
    // Указываем MIME-тип — важно для Safari
    final mime = _actualMimeType ?? 'audio/mp4';
    if (_blobUrl != null) html.Url.revokeObjectUrl(_blobUrl!);
    _htmlAudio?.remove();

    final blob = html.Blob([bytes], mime);
    _blobUrl = html.Url.createObjectUrlFromBlob(blob);
    _htmlAudio = html.AudioElement(_blobUrl!)
      ..onEnded.listen(_webOnEnded)
      ..onError.listen(_webOnError)
      ..load(); // начинаем буферизацию
  }

  /// Скачать аудио-файл (для неподдерживаемых форматов)
  void _downloadAudio() {
    if (_blobUrl == null) return;
    final anchor = html.AnchorElement(href: _blobUrl!)
      ..setAttribute('download', widget.event.body.isNotEmpty ? widget.event.body : 'voice.weba')
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    if (_blobUrl != null && kIsWeb) {
      html.Url.revokeObjectUrl(_blobUrl!);
    }
    _htmlAudio?.remove();
    _htmlAudio = null;
    _nativePlayer?.dispose();
    super.dispose();
  }

  void _webUpdateProgress(Timer _) {
    if (_htmlAudio != null && mounted) {
      final dur = _htmlAudio!.duration;
      final pos = _htmlAudio!.currentTime;
      if (dur.isNaN || dur.isInfinite) return;
      setState(() {
        _duration = Duration(milliseconds: (dur * 1000).round());
        _position = Duration(milliseconds: (pos * 1000).round());
        _isPlaying = !_htmlAudio!.paused;
        _isInitialized = true;
      });
    }
  }

  void _webOnEnded(html.Event _) {
    _progressTimer?.cancel();
    if (mounted) setState(() { _isPlaying = false; _position = Duration.zero; });
  }

  void _webOnError(html.Event _) {
    _progressTimer?.cancel();
    if (mounted) setState(() { _isUnsupported = true; _isPlaying = false; });
  }

  Future<void> _loadAndPlay() async {
    if (_isLoading) return;
    if (_isUnsupported) {
      _downloadAudio();
      return;
    }

    // Уже загружено — переключить play/pause
    if (_isInitialized) {
      if (kIsWeb && _htmlAudio != null) {
        if (_isPlaying) {
          _htmlAudio!.pause();
          _progressTimer?.cancel();
          setState(() => _isPlaying = false);
        } else {
          await _htmlAudio!.play();
          _progressTimer = Timer.periodic(const Duration(milliseconds: 100), _webUpdateProgress);
          setState(() => _isPlaying = true);
        }
        return;
      }
      if (!kIsWeb && _nativePlayer != null) {
        if (_isPlaying) {
          await _nativePlayer!.pause();
        } else {
          await _nativePlayer!.resume();
        }
        return;
      }
    }

    setState(() { _isLoading = true; _errorMessage = null; });

    try {
      // Используем предзагруженные байты если есть, иначе качаем сейчас
      Uint8List bytes;
      if (_preloadedBytes != null && _preloadedBytes!.isNotEmpty) {
        bytes = _preloadedBytes!;
      } else {
        try {
          bytes = (await widget.event.downloadAndDecryptAttachment()).bytes;
        } catch (_) {
          bytes = (await widget.mediaService.authenticatedMediaDownload(widget.event))!;
        }
        _preloadedBytes = bytes;
        // Определяем MIME если ещё не
        _actualMimeType ??= widget.event.attachmentMimetype.isNotEmpty
            ? widget.event.attachmentMimetype
            : _detectMimeFromName(widget.event.body);
        if (kIsWeb) {
          _isUnsupported = _checkUnsupported(_actualMimeType ?? '');
        }
      }

      if (bytes.isEmpty) {
        setState(() => _errorMessage = "Пустой файл");
        return;
      }

      if (_isUnsupported) {
        setState(() {});
        return;
      }

      if (kIsWeb) {
        if (_htmlAudio == null) _createWebAudio(bytes);
        if (_htmlAudio == null) {
          debugPrint('[Audio] Failed to create web audio element');
          return;
        }
        await _htmlAudio!.play();
        _progressTimer = Timer.periodic(const Duration(milliseconds: 100), _webUpdateProgress);
      } else {
        final tempDir = Directory.systemTemp;
        final bodyName = widget.event.body;
        final extension = bodyName.contains('.') ? bodyName.split('.').last : 'm4a';
        final file = File('${tempDir.path}/audioplayer_${widget.event.eventId}.$extension');
        await file.writeAsBytes(bytes);
        await _nativePlayer!.play(DeviceFileSource(file.path));
      }
      _isPlaying = true;
      _isInitialized = true;
    } catch (e) {
      if (kIsWeb) {
        // На web ошибка play часто означает неподдерживаемый формат
        _isUnsupported = true;
      } else {
        setState(() => _errorMessage = "Ошибка загрузки");
      }
      debugPrint("Audio player error: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds > 0
        ? _position.inMilliseconds / _duration.inMilliseconds
        : 0.0;

    // Кнопка: play/pause, загрузка, или скачать (неподдерживаемый формат)
    Widget actionButton;
    if (_isLoading) {
      actionButton = const SizedBox(
        width: 36,
        height: 36,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (_isUnsupported) {
      actionButton = IconButton(
        icon: const Icon(Icons.download, size: 30),
        color: widget.isMe ? Colors.white : Colors.indigo,
        tooltip: 'Скачать аудио',
        onPressed: _downloadAudio,
      );
    } else {
      actionButton = IconButton(
        icon: Icon(
          _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
          size: 36,
          color: widget.isMe ? Colors.white : Colors.indigo,
        ),
        onPressed: _loadAndPlay,
      );
    }

    // Текст под прогресс-баром
    String infoText;
    if (_isUnsupported) {
      infoText = 'Формат не поддерживается — скачать';
    } else if (_errorMessage != null) {
      infoText = _errorMessage!;
    } else if (_isInitialized) {
      infoText = '${_formatDuration(_position)} / ${_formatDuration(_duration)}';
    } else {
      infoText = widget.event.body;
    }

    return Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              actionButton,
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Progress bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: _isUnsupported ? 0 : progress,
                        minHeight: 3,
                        backgroundColor:
                            (widget.isMe ? Colors.white : Colors.grey).withValues(alpha: 0.3),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _isUnsupported
                              ? Colors.orange
                              : (widget.isMe ? Colors.white : Colors.indigo),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Info text
                    Text(
                      infoText,
                      style: TextStyle(
                        fontSize: 11,
                        color: _isUnsupported || _errorMessage != null
                            ? Colors.orange
                            : (widget.isMe ? Colors.white70 : Colors.grey[600]),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Виджет видеоплеера для видеосообщений.
/// Показывает превью-карточку с кнопкой Play, при нажатии открывает полноэкранное видео.
class _VideoPlayerWidget extends StatefulWidget {
  final Event event;
  final bool isMe;
  final MediaService mediaService;

  const _VideoPlayerWidget({
    required this.event,
    required this.isMe,
    required this.mediaService,
  });

  @override
  State<_VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<_VideoPlayerWidget> {
  bool _isDownloading = false;
  bool _isLoadingThumb = false;
  String? _thumbDataUrl; // base64 data URL первого кадра

  @override
  void initState() {
    super.initState();
    if (kIsWeb) _loadThumbnail();
  }

  /// Web: скачивает видео и извлекает первый кадр через canvas
  Future<void> _loadThumbnail() async {
    if (_isLoadingThumb) return;
    setState(() => _isLoadingThumb = true);

    try {
      Uint8List? bytes;
      try {
        bytes = (await widget.event.downloadAndDecryptAttachment()).bytes;
      } catch (_) {
        bytes = await widget.mediaService.authenticatedMediaDownload(widget.event);
      }
      if (bytes == null || bytes.isEmpty) return;

      final bodyName = widget.event.body;
      final ext = bodyName.contains('.') ? bodyName.split('.').last : 'mp4';
      final mimeType = ext == 'webm' ? 'video/webm' : 'video/mp4';
      final blob = html.Blob([bytes], mimeType);
      final blobUrl = html.Url.createObjectUrlFromBlob(blob);

      final video = html.VideoElement()
        ..src = blobUrl
        ..style.display = 'none'
        ..preload = 'metadata';

      html.document.body?.append(video);

      final completer = Completer<String?>();
      // Пытаемся извлечь кадр из середины видео
      html.EventListener? onLoaded;
      onLoaded = (_) {
        video.currentTime = video.duration * 0.1; // ~10% от начала
      };
      video.onLoadedMetadata.listen(onLoaded);
      video.onSeeked.listen((_) {
        try {
          final canvas = html.CanvasElement(width: 200, height: 140);
          final ctx = canvas.context2D;
          ctx.drawImageScaled(video, 0, 0, 200, 140);
          final dataUrl = canvas.toDataUrl('image/jpeg', 0.7);
          completer.complete(dataUrl);
        } catch (_) {
          completer.complete(null);
        }
      });
      video.onError.listen((_) {
        completer.complete(null);
      });
      // Таймаут 10 секунд
      Timer(const Duration(seconds: 10), () {
        if (!completer.isCompleted) completer.complete(null);
      });

      final dataUrl = await completer.future;
      video.remove();
      html.Url.revokeObjectUrl(blobUrl);

      if (dataUrl != null && mounted) {
        setState(() => _thumbDataUrl = dataUrl);
      }
    } catch (e) {
      debugPrint("Thumbnail error: $e");
    } finally {
      if (mounted) setState(() => _isLoadingThumb = false);
    }
  }

  Future<void> _downloadAndPlay() async {
    if (_isDownloading) return;

    setState(() => _isDownloading = true);

    try {
      Uint8List? bytes;
      try {
        bytes = (await widget.event.downloadAndDecryptAttachment()).bytes;
      } catch (_) {
        bytes = await widget.mediaService.authenticatedMediaDownload(widget.event);
      }

      if (bytes == null || bytes.isEmpty) return;

      if (kIsWeb) {
        // Web: создаём <video> элемент и открываем fullscreen
        // (window.open блокируется popup blocker'ами на мобильных браузерах)
        final bodyName = widget.event.body;
        final ext = bodyName.contains('.') ? bodyName.split('.').last : 'mp4';
        final mimeType = ext == 'webm' ? 'video/webm' : 'video/mp4';

        final blob = html.Blob([bytes], mimeType);
        final blobUrl = html.Url.createObjectUrlFromBlob(blob);

        final video = html.VideoElement()
          ..src = blobUrl
          ..controls = true
          ..autoplay = true
          ..style.position = 'fixed'
          ..style.top = '0'
          ..style.left = '0'
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.zIndex = '2147483647'
          ..style.backgroundColor = 'black';

        void cleanup() {
          video.pause();
          video.remove();
          html.Url.revokeObjectUrl(blobUrl);
        }

        video.onEnded.listen((_) => cleanup());
        video.onError.listen((_) => cleanup());
        html.document.onFullscreenChange.listen((_) {
          if (html.document.fullscreenElement == null) {
            cleanup();
            html.document.onFullscreenChange.listen((_) {}); // remove listener
          }
        });

        html.document.body?.append(video);
        try {
          video.requestFullscreen();
        } catch (_) {
          // iOS Safari не поддерживает Fullscreen API — оверлей работает сам
        }
      } else {
        // Native: сохраняем во временный файл и открываем плеер
        final tempDir = Directory.systemTemp;
        final bodyName = widget.event.body;
        final extension = bodyName.contains('.') ? bodyName.split('.').last : 'mp4';
        final file = File('${tempDir.path}/video_${widget.event.eventId}.$extension');
        await file.writeAsBytes(bytes);

        if (mounted) {
          _openVideoPlayer(context, file.path, isBlob: false);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка загрузки видео: $e"), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  void _openVideoPlayer(BuildContext context, String pathOrUrl, {required bool isBlob}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullscreenVideoPage(pathOrUrl: pathOrUrl, isBlob: isBlob),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasThumb = _thumbDataUrl != null;

    return Container(
      width: 200,
      height: 140,
      decoration: BoxDecoration(
        color: widget.isMe ? Colors.indigo[300] : Colors.grey[300],
        borderRadius: BorderRadius.circular(8),
        image: hasThumb
            ? DecorationImage(
                image: NetworkImage(_thumbDataUrl!),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Placeholder icon — показывается только пока нет превью
          if (!hasThumb && !_isLoadingThumb)
            Icon(
              Icons.videocam,
              size: 48,
              color: widget.isMe ? Colors.white54 : Colors.grey[500],
            ),
          // Spinner загрузки превью
          if (_isLoadingThumb)
            const CircularProgressIndicator(strokeWidth: 3, color: Colors.white54),
          // Play button
          if (!_isLoadingThumb)
            _isDownloading
                ? const CircularProgressIndicator(strokeWidth: 3)
                : Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.play_arrow, color: Colors.white, size: 28),
                      onPressed: _downloadAndPlay,
                    ),
                  ),
          // File name at bottom
          Positioned(
            bottom: 4,
            left: 8,
            right: 8,
            child: Text(
              widget.event.body,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: hasThumb ? Colors.white : (widget.isMe ? Colors.white70 : Colors.grey[700]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Полноэкранное воспроизведение видео.
class _FullscreenVideoPage extends StatefulWidget {
  final String pathOrUrl;
  final bool isBlob;

  const _FullscreenVideoPage({required this.pathOrUrl, required this.isBlob});

  @override
  State<_FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<_FullscreenVideoPage> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    if (widget.isBlob || kIsWeb) {
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.pathOrUrl));
    } else {
      _controller = VideoPlayerController.file(File(widget.pathOrUrl));
    }
    _controller.initialize().then((_) {
      if (mounted) {
        setState(() => _isInitialized = true);
        _controller.play();
      }
    }).catchError((e) {
      debugPrint('[VIDEO] Init error: $e');
    });
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    // Revoke blob URL to free memory
    if (widget.isBlob && widget.pathOrUrl.startsWith('blob:')) {
      html.Url.revokeObjectUrl(widget.pathOrUrl);
    }
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text("Видео", style: TextStyle(color: Colors.white)),
      ),
      body: _isInitialized
          ? Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _controller.value.aspectRatio,
                      child: VideoPlayer(_controller),
                    ),
                  ),
                ),
                // Controls
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: Colors.black87,
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          if (_controller.value.isPlaying) {
                            _controller.pause();
                          } else {
                            _controller.play();
                          }
                        },
                      ),
                      Expanded(
                        child: VideoProgressIndicator(
                          _controller,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: Colors.blue,
                            bufferedColor: Colors.grey,
                            backgroundColor: Colors.white30,
                          ),
                        ),
                      ),
                      Text(
                        '${_formatDuration(_controller.value.position)} / ${_formatDuration(_controller.value.duration)}',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator(color: Colors.white)),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
