import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:file_picker/file_picker.dart';
import '../services/media_service.dart';

/// Виджет панели ввода сообщений внизу чата.
///
/// Включает:
/// - Reply preview bar (если [replyToEvent] не null)
/// - Строка с кнопкой attach, TextField, кнопка send
/// - Attachment menu (bottom sheet): галерея, камера, файл
/// - Отправка текста, изображений, файлов
class InputBar extends StatefulWidget {
  final Room room;
  final Event? replyToEvent;
  final bool isSending;
  final VoidCallback onReplyCleared;
  final VoidCallback onSendingChanged;
  final MediaService mediaService;

  const InputBar({
    super.key,
    required this.room,
    this.replyToEvent,
    required this.isSending,
    required this.onReplyCleared,
    required this.onSendingChanged,
    required this.mediaService,
  });

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final _controller = TextEditingController();
  final _inputFocusNode = FocusNode();

  /// Внутренний флаг отправки для файловых операций (выбор файла + отправка).
  /// Позволяет заблокировать UI на время выбора файла, до вызова
  /// [InputBar.onSendingChanged] в родителе.
  bool _isSendingInternal = false;

  /// Общий признак отправки: родительский + внутренний.
  bool get _isSending => widget.isSending || _isSendingInternal;

  @override
  void dispose() {
    _controller.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  // ===================== SEND TEXT =====================

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    _controller.clear();
    widget.onReplyCleared();
    widget.onSendingChanged(); // parent: _isSending = true

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
      widget.onSendingChanged(); // parent: _isSending = false
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
    };
    return mimeMap[ext];
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
    final senderName = event.senderId.localpart ?? 'User';
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
          // Input row
          Row(
            children: [
              // Attach button
              IconButton(
                icon: const Icon(Icons.attach_file, color: Colors.indigo),
                onPressed: _isSending ? null : _showAttachmentMenu,
              ),
              // Text field
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
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
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Send button
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
                        icon: const Icon(
                          Icons.send,
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
