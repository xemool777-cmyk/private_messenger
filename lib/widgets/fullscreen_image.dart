import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../services/media_service.dart';

/// Полноэкранный просмотр изображения с зумом и панорамированием.
///
/// Использует [MediaService] для загрузки — кеширование, authenticated media
/// (MSC3916), расшифровка зашифрованных вложений, fallback на legacy v3.
class FullscreenImageView extends StatefulWidget {
  final Event event;
  final Uint8List? cachedBytes;
  final MediaService mediaService;

  const FullscreenImageView({
    super.key,
    required this.event,
    this.cachedBytes,
    required this.mediaService,
  });

  @override
  State<FullscreenImageView> createState() => _FullscreenImageViewState();
}

class _FullscreenImageViewState extends State<FullscreenImageView> {
  final TransformationController _transformController =
      TransformationController();

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  Future<Uint8List?> _downloadImage() async {
    // Если байты уже переданы — используем их (из кеша чата)
    if (widget.cachedBytes != null) return widget.cachedBytes!;

    // Загрузка через MediaService (кеш + authenticated + legacy + decrypt)
    try {
      final bytes = await widget.mediaService.getImageBytes(widget.event);
      if (bytes != null && bytes.isNotEmpty) return bytes;
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
          widget.event.body,
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

            if (snapshot.hasData &&
                snapshot.data != null &&
                snapshot.data!.isNotEmpty) {
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
                      Icon(Icons.broken_image,
                          color: Colors.white54, size: 64),
                      SizedBox(height: 12),
                      Text(
                        'Не удалось отобразить',
                        style: TextStyle(color: Colors.white54),
                      ),
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
                Text(
                  'Не удалось загрузить',
                  style: TextStyle(color: Colors.white54),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
