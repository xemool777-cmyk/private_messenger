import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../helpers/camera_video.dart';
import '../services/media_service.dart';

/// Виджет панели ввода сообщений внизу чата.
///
/// Включает:
/// - Reply preview bar (если [replyToEvent] не null)
/// - Edit bar (если [editEvent] не null)
/// - Строка с кнопкой attach, TextField, кнопка send
/// - Attachment menu (bottom sheet): галерея, камера, файл
class InputBar extends StatefulWidget {
  final Room room;
  final Event? replyToEvent;
  final Event? editEvent;
  final bool isSending;
  final VoidCallback onReplyCleared;
  final VoidCallback onEditCleared;
  final VoidCallback onSendingChanged;
  final MediaService mediaService;

  const InputBar({
    super.key,
    required this.room,
    this.replyToEvent,
    this.editEvent,
    required this.isSending,
    required this.onReplyCleared,
    required this.onEditCleared,
    required this.onSendingChanged,
    required this.mediaService,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final _controller = TextEditingController();
  final _inputFocusNode = FocusNode();
  Timer? _typingTimer;
  bool _isTyping = false;

  /// Внутренний флаг отправки для файловых операций (выбор файла + отправка).
  /// Позволяет заблокировать UI на время выбора файла, до вызова
  /// [InputBar.onSendingChanged] в родителе.
  bool _isSendingInternal = false;

  final _audioRecorder = AudioRecorder();
  bool _isRecording = false;

  /// Общий признак отправки: родительский + внутренний.
  bool get _isSending => widget.isSending || _isSendingInternal;

  @override
  void didUpdateWidget(covariant InputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // При входе в режим редактирования — предзаполнить текст
    if (widget.editEvent != oldWidget.editEvent) {
      if (widget.editEvent != null) {
        _controller.text = widget.editEvent!.body;
        _inputFocusNode.requestFocus();
      } else {
        _controller.clear();
      }
    }
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    if (_isTyping) {
      widget.room.setTyping(false); // fire-and-forget
    }
    _audioRecorder.dispose();
    _controller.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  // ===================== SEND TEXT =====================

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    // Если в режиме редактирования — отправляем edit, а не новое сообщение
    if (widget.editEvent != null) {
      return _sendEditedMessage(text);
    }

    _controller.clear();
    widget.onReplyCleared();
    widget.onSendingChanged();

    try {
      await widget.room.sendTextEvent(
        text,
        inReplyTo: widget.replyToEvent,
      );
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
      widget.onSendingChanged();
    }
  }

  // ===================== TYPING INDICATOR (P2.7) =====================

  void _emitTyping(bool typing) {
    if (typing && !_isTyping) {
      _isTyping = true;
      widget.room.setTyping(true);
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 4), () {
      if (_isTyping) {
        _isTyping = false;
        widget.room.setTyping(false);
      }
    });
  }

  /// Отправка отредактированного сообщения по Matrix-протоколу.
  /// 
  /// Согласно спецификации:
  /// - Отправляем m.room.message с m.new_content (оригинальное поле — body)
  /// - m.relates_to с rel_type: m.replace и event_id исходного события
  Future<void> _sendEditedMessage(String newText) async {
    final editEvent = widget.editEvent!;

    _controller.clear();
    widget.onSendingChanged();

    try {
      await widget.room.sendEvent(
        <String, dynamic>{
          'msgtype': 'm.text',
          'body': ' * $newText',
          'm.new_content': <String, dynamic>{
            'msgtype': 'm.text',
            'body': newText,
          },
          'm.relates_to': <String, dynamic>{
            'rel_type': 'm.replace',
            'event_id': editEvent.eventId,
          },
        },
        type: 'm.room.message',
      );
      // Очистка edit-состояния ТОЛЬКО после успешной отправки
      widget.onEditCleared();
    } catch (e) {
      // Восстановить введённый текст при ошибке, сохранить режим редактирования
      _controller.text = newText;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка редактирования: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      widget.onSendingChanged();
    }
  }

  // ===================== SEND IMAGE =====================

  Future<void> _sendImage() async {
    setState(() => _isSendingInternal = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null) return;

      widget.onSendingChanged(); // parent: _isSending = true
      final matrixFile = MatrixImageFile(
        bytes: file.bytes!,
        name: file.name,
        mimeType: _getMimeType(file.name, file.extension),
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
      widget.onSendingChanged(); // parent: _isSending = false
      if (mounted) setState(() => _isSendingInternal = false);
    }
  }

  // ===================== SEND FILE =====================

  Future<void> _sendFile() async {
    setState(() => _isSendingInternal = true);
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

      widget.onSendingChanged(); // parent: _isSending = true
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
      widget.onSendingChanged(); // parent: _isSending = false
      if (mounted) setState(() => _isSendingInternal = false);
    }
  }

  // ===================== SEND AUDIO =====================

  /// Запись и отправка аудиосообщения
  Future<void> _sendAudio() async {
    if (kIsWeb) {
      await _sendAudioWeb();
    } else {
      await _sendAudioNative();
    }
  }

  /// Web: запись аудио через record_web (MediaRecorder браузера)
  Future<void> _sendAudioWeb() async {
    setState(() => _isRecording = true);
    // Не дёргаем onSendingChanged — отправка начнётся только в _stopRecordingAndSendWeb

    try {
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 44100,
          bitRate: 128000,
        ),
        path: '',
      );
    } catch (e) {
      setState(() => _isRecording = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Native (Android/iOS/Desktop): запись аудио через record + permission_handler
  Future<void> _sendAudioNative() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Нет доступа к микрофону"),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    if (!await _audioRecorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Запись аудио не поддерживается"),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    setState(() => _isRecording = true);
    // Не дёргаем onSendingChanged — отправка начнётся только в _stopRecordingAndSendNative

    try {
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 44100,
          bitRate: 128000,
        ),
        path:
            '${Directory.systemTemp.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
    } catch (e) {
      setState(() => _isRecording = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Остановить запись аудио и отправить
  Future<void> _stopRecordingAndSend() async {
    if (!_isRecording) return;

    if (kIsWeb) {
      await _stopRecordingAndSendWeb();
    } else {
      await _stopRecordingAndSendNative();
    }
  }

  /// Web: остановка записи — record_web возвращает blob URL, скачиваем через HTTP
  Future<void> _stopRecordingAndSendWeb() async {
    if (!_isRecording) return;

    setState(() => _isSendingInternal = true);
    var sent = false; // чтобы finally знал, вызывался ли onSendingChanged

    try {
      final blobUrl = await _audioRecorder.stop();
      if (blobUrl == null || blobUrl.isEmpty) return;

      // Скачиваем blob по URL
      final response = await http.get(Uri.parse(blobUrl));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return;

      final bytes = response.bodyBytes;
      // Определяем реальный формат по магическим байтам
      final actualMime = _detectAudioFormat(bytes);
      final (ext, mimeType) = switch (actualMime) {
        'audio/mp4' => ('m4a', 'audio/mp4'),
        'audio/mpeg' => ('mp3', 'audio/mpeg'),
        'audio/ogg' => ('ogg', 'audio/ogg'),
        'audio/wav' => ('wav', 'audio/wav'),
        _ => ('weba', 'audio/webm'),
      };
      sent = true;
      widget.onSendingChanged();
      final matrixFile = MatrixFile(
        bytes: bytes,
        name: 'voice_${DateTime.now().millisecondsSinceEpoch}.$ext',
        mimeType: mimeType,
      );
      await widget.room.sendFileEvent(matrixFile);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка: $e"), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (sent) widget.onSendingChanged();
      setState(() { _isRecording = false; _isSendingInternal = false; });
    }
  }

  /// Native: остановка записи — record возвращает путь к файлу
  Future<void> _stopRecordingAndSendNative() async {
    if (!_isRecording) return;

    setState(() => _isSendingInternal = true);
    var sent = false;

    try {
      final path = await _audioRecorder.stop();
      if (path == null || !File(path).existsSync()) return;

      final file = File(path);
      final bytes = await file.readAsBytes();

      if (bytes.isEmpty) return;

      sent = true;
      widget.onSendingChanged();
      final matrixFile = MatrixFile(
        bytes: bytes,
        name: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
        mimeType: 'audio/mp4',
      );
      await widget.room.sendFileEvent(matrixFile);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка: $e"), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (sent) widget.onSendingChanged();
      setState(() { _isRecording = false; _isSendingInternal = false; });
    }
  }

  // ===================== SEND VIDEO =====================

  /// Запись и отправка видеосообщения
  Future<void> _sendVideo() async {
    if (kIsWeb) {
      await _sendVideoWeb();
    } else {
      await _sendVideoNative();
    }
  }

  /// Web: запись видео через <input capture> — открывает камеру напрямую,
  /// без файлового диалога (файлы и медиатека уже есть в других кнопках).
  Future<void> _sendVideoWeb() async {
    setState(() => _isSendingInternal = true);
    var sent = false; // чтобы finally знал, вызывался ли onSendingChanged

    try {
      final picked = await pickVideoFromCamera();
      if (picked == null) return; // пользователь отменил

      if (picked.bytes.isEmpty) return;

      sent = true;
      widget.onSendingChanged();
      final matrixFile = MatrixFile(
        bytes: picked.bytes,
        name: picked.name,
        mimeType: 'video/mp4',
      );
      await widget.room.sendFileEvent(matrixFile);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка отправки видео: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (sent) widget.onSendingChanged();
      if (mounted) setState(() => _isSendingInternal = false);
    }
  }

  /// Native: запись видео через image_picker + камера
  Future<void> _sendVideoNative() async {
    final camStatus = await Permission.camera.request();
    final micStatus = await Permission.microphone.request();
    if (!camStatus.isGranted || !micStatus.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Нужен доступ к камере и микрофону"),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    setState(() => _isSendingInternal = true);

    try {
      final picker = ImagePicker();
      final xFile = await picker.pickVideo(
        source: ImageSource.camera,
        maxDuration: const Duration(seconds: 60),
      );

      if (xFile == null) {
        setState(() => _isSendingInternal = false);
        return;
      }

      widget.onSendingChanged();
      final file = File(xFile.path);
      final bytes = await file.readAsBytes();

      final matrixFile = MatrixFile(
        bytes: bytes,
        name: 'video_${DateTime.now().millisecondsSinceEpoch}.mp4',
        mimeType: 'video/mp4',
      );
      await widget.room.sendFileEvent(matrixFile);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка записи видео: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      widget.onSendingChanged();
      if (mounted) setState(() => _isSendingInternal = false);
    }
  }

  // ===================== MIME TYPE =====================

  /// Определяет MIME-тип по расширению файла.
  /// Использует встроенную карту популярных типов.
  String? _getMimeType(String name, String? extension) {
    final ext = (extension ?? name.split('.').last).toLowerCase();
    const mimeMap = {
      'pdf': 'application/pdf',
      'doc': 'application/msword',
      'docx':
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'txt': 'text/plain',
      'zip': 'application/zip',
      'mp3': 'audio/mpeg',
      'mp4': 'video/mp4',
      'm4a': 'audio/mp4',
      'ogg': 'audio/ogg',
      'mov': 'video/quicktime',
    };
    return mimeMap[ext];
  }

  /// Определяет аудио-формат по магическим байтам в начале файла.
  /// Нужно чтобы правильно указать MIME-тип для Matrix и для воспроизведения.
  String _detectAudioFormat(Uint8List bytes) {
    if (bytes.length < 4) return 'audio/webm';
    // WebM (EBML header): 1A 45 DF A3
    if (bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3) {
      return 'audio/webm';
    }
    // MP4/M4A (ISOBMFF): ftyp box at offset 4
    if (bytes.length >= 12 &&
        bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x00 &&
        bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) {
      return 'audio/mp4';
    }
    // OGG: OggS
    if (bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53) {
      return 'audio/ogg';
    }
    // WAV: RIFF
    if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) {
      return 'audio/wav';
    }
    // MP3: ID3 tag (49 44 33) or sync bits (FF FB/F3/F2)
    if ((bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) ||
        (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33)) {
      return 'audio/mpeg';
    }
    return 'audio/webm';
  }

  // ===================== ATTACHMENT MENU =====================

  /// Показывает bottom sheet с опциями вложений: галерея, камера, файл.
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
                        final messenger = ScaffoldMessenger.of(context);
                        Navigator.pop(context);
                        try {
                          final result = await FilePicker.platform.pickFiles(
                            type: FileType.image,
                            withData: true,
                          );
                          if (result == null || result.files.isEmpty) return;
                          final file = result.files.first;
                          if (file.bytes == null) return;

                          setState(() => _isSendingInternal = true);
                          widget.onSendingChanged(); // parent: _isSending = true
                          final matrixFile = MatrixImageFile(
                            bytes: file.bytes!,
                            name: file.name,
                            mimeType:
                                _getMimeType(file.name, file.extension),
                          );
                          await widget.room.sendFileEvent(matrixFile);
                        } catch (e) {
                          if (mounted) {
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text("Ошибка: $e"),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        } finally {
                          widget.onSendingChanged(); // parent: _isSending = false
                          if (mounted) {
                            setState(() => _isSendingInternal = false);
                          }
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _attachOption(
                      icon: Icons.mic,
                      label: "Аудио",
                      color: Colors.teal,
                      onTap: () {
                        Navigator.pop(context);
                        // Задержка, чтобы bottom sheet успел закрыться и
                        // браузер получил свежий user gesture для getUserMedia
                        Future.delayed(
                          const Duration(milliseconds: 300),
                          _sendAudio,
                        );
                      },
                    ),
                    const SizedBox(width: 24),
                    _attachOption(
                      icon: Icons.videocam,
                      label: "Видео",
                      color: Colors.red,
                      onTap: () {
                        Navigator.pop(context);
                        _sendVideo();
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

  /// Виджет опции вложения в bottom sheet.
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
                color: color.withValues(alpha: 0.1),
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

  // ===================== REPLY PREVIEW =====================

  /// Превью цитируемого сообщения над строкой ввода.
  Widget _buildReplyPreview() {
    if (widget.replyToEvent == null) return const SizedBox.shrink();
    final event = widget.replyToEvent!;
    final senderName = event.senderId?.localpart ?? 'User';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.indigo[50],
        border: const Border(
          left: BorderSide(color: Colors.indigo, width: 3),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  senderName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: Colors.indigo,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _getReplySnippet(event),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: _cancelReply,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  /// Возвращает краткое текстовое описание события для превью цитаты.
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

  /// Отменяет цитирование и фокусирует поле ввода.
  void _cancelReply() {
    widget.onReplyCleared();
    _inputFocusNode.requestFocus();
  }

  // ===================== EDIT BAR =====================

  /// Панель редактирования сообщения над полем ввода.
  Widget _buildEditBar() {
    if (widget.editEvent == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.orange[50],
        border: const Border(
          left: BorderSide(color: Colors.orange, width: 3),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit, size: 16, color: Colors.orange),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              "Редактирование",
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: Colors.orange,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: _cancelEdit,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  void _cancelEdit() {
    widget.onEditCleared();
    _controller.clear();
    _inputFocusNode.requestFocus();
  }

  // ===================== BUILD =====================

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.grey[300]!,
            blurRadius: 4,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Reply preview bar
          _buildReplyPreview(),
          // Edit bar (приоритетнее reply)
          _buildEditBar(),
          // Input row
          Row(
            children: [
              // Attach button (скрыт в режиме редактирования и записи)
              if (widget.editEvent == null && !_isRecording)
                IconButton(
                  icon: const Icon(Icons.attach_file, color: Colors.indigo),
                  onPressed: _isSending ? null : _showAttachmentMenu,
                ),
              // Text field / Recording indicator
              _isRecording
                  ? Expanded(
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.red[50],
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.red[300]!),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              "Запись...",
                              style: TextStyle(
                                color: Colors.red,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.stop,
                                  color: Colors.red),
                              onPressed: _stopRecordingAndSend,
                              tooltip: "Остановить запись и отправить",
                            ),
                          ],
                        ),
                      ),
                    )
                  : Expanded(
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: TextField(
                          controller: _controller,
                          focusNode: _inputFocusNode,
                          decoration: const InputDecoration(
                            hintText: "Сообщение...",
                            border: InputBorder.none,
                          ),
                          minLines: 1,
                          maxLines: 5,
                          onChanged: (_) => _emitTyping(true),
                          onSubmitted: (_) => _sendMessage(),
                        ),
                      ),
                    ),
              const SizedBox(width: 8),
              // Send / Save edit button (скрыт во время записи)
              if (!_isRecording)
                CircleAvatar(
                  backgroundColor: widget.editEvent != null
                      ? Colors.orange
                      : Colors.indigo,
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
                          icon: Icon(
                            widget.editEvent != null
                                ? Icons.check
                                : Icons.send,
                            color: Colors.white,
                            size: 20,
                          ),
                          onPressed: _sendMessage,
                        ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
