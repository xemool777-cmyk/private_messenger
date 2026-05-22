import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
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
  });

  // ===================== BUILD =====================

  @override
  Widget build(BuildContext context) {
    final isFailed = isMe && event.status == EventStatus.error;
    final isMedia = event.messageType == MessageTypes.Image ||
        event.messageType == MessageTypes.Video;

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
                        (event.senderId.localpart ?? '?')[0].toUpperCase(),
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
      ],
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

    // Видео, аудио, файл
    if (msgType == MessageTypes.Video) {
      return _buildFileCard(
        context, event, isMe, Icons.video_file, Colors.red,
      );
    }
    if (msgType == MessageTypes.Audio) {
      return _buildFileCard(
        context, event, isMe, Icons.audio_file, Colors.orange,
      );
    }
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

  Future<void> _downloadFile(BuildContext context, Event event) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Скачивание..."),
        ),
      );

      Uint8List? fileBytes;
      final mxcUrl = event.attachmentMxcUrl;

      if (mxcUrl != null) {
        fileBytes = await mediaService.authenticatedMediaDownload(event);
      }

      fileBytes ??= (await event.downloadAndDecryptAttachment()).bytes;

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
            repliedEvent.senderId.localpart ?? 'User',
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
    return Row(
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
