import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../services/media_service.dart';

/// Виджет для отображения изображения в пузыре сообщения чата.
///
/// Использует [MediaService] для кеширования и загрузки:
/// 1. Сначала проверяет LRU-кеш через [LruImageCache.get]
/// 2. Если нет в кеше — вызывает [MediaService.getImageBytes] через FutureBuilder
/// 3. При успехе кеширует байты внутренне для быстрых перестроек
/// 4. По нажатию вызывает [onTap] с событием (для fullscreen)
class ImageGalleryWidget extends StatefulWidget {
  final Event event;
  final MediaService mediaService;
  final void Function(Event) onTap;

  const ImageGalleryWidget({
    super.key,
    required this.event,
    required this.mediaService,
    required this.onTap,
  });

  @override
  State<ImageGalleryWidget> createState() => _ImageGalleryWidgetState();
}

class _ImageGalleryWidgetState extends State<ImageGalleryWidget> {
  /// Локально закешированные байты (из MediaService.cache либо результат FutureBuilder)
  Uint8List? _cachedBytes;

  @override
  void initState() {
    super.initState();
    _cachedBytes = widget.mediaService.cache.get(widget.event.eventId);
  }

  @override
  void didUpdateWidget(ImageGalleryWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.eventId != widget.event.eventId) {
      // При смене события сбрасываем и проверяем кеш заново
      _cachedBytes = widget.mediaService.cache.get(widget.event.eventId);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Если байты уже в кеше — отображаем сразу без FutureBuilder
    if (_cachedBytes != null) {
      return _buildImage(_cachedBytes!);
    }

    return FutureBuilder<Uint8List?>(
      future: widget.mediaService.getImageBytes(widget.event),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildLoading();
        }

        if (snapshot.hasData &&
            snapshot.data != null &&
            snapshot.data!.isNotEmpty) {
          final bytes = snapshot.data!;

          if (MediaService.looksLikeImage(bytes)) {
            // Сохраняем локально, чтобы FutureBuilder не пересоздавался
            _cachedBytes = bytes;
            return _buildImage(bytes);
          }

          return _buildError('Не картинка (${bytes.length} байт)');
        }

        return _buildError('Не удалось загрузить');
      },
    );
  }

  /// Основной виджет изображения с обработчиком нажатия
  Widget _buildImage(Uint8List bytes) {
    return GestureDetector(
      onTap: () => widget.onTap(widget.event),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: min(MediaQuery.of(context).size.width * 0.65, 300),
            maxHeight: 300,
          ),
          child: Image.memory(
            bytes,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _buildError('Ошибка декодирования'),
          ),
        ),
      ),
    );
  }

  /// Индикатор загрузки
  Widget _buildLoading() {
    return Container(
      width: 200,
      height: 150,
      color: Colors.grey[200],
      child: const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  /// Виджет ошибки с иконкой и текстом причины
  Widget _buildError(String reason) {
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
            reason,
            style: const TextStyle(color: Colors.grey, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
