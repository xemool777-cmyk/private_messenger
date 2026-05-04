import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

/// Инлайн-аудиоплеер для голосовых сообщений в чате
/// Поддерживает воспроизведение из байтов (скачанный файл) или URL
class AudioPlayerWidget extends StatefulWidget {
  final Uint8List? audioBytes;
  final String? audioUrl;
  final Duration? duration;
  final bool isMe;

  const AudioPlayerWidget({
    super.key,
    this.audioBytes,
    this.audioUrl,
    this.duration,
    required this.isMe,
  });

  @override
  State<AudioPlayerWidget> createState() => _AudioPlayerWidgetState();
}

class _AudioPlayerWidgetState extends State<AudioPlayerWidget> {
  late final AudioPlayer _player;
  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _setupPlayer();
  }

  Future<void> _setupPlayer() async {
    _player.playbackEventStream.listen(
      (event) {
        if (mounted) {
          setState(() {
            _currentPosition = _player.position;
            _totalDuration = _player.duration ?? widget.duration ?? Duration.zero;
            _isPlaying = _player.playing;
            _isLoading = _player.processingState == ProcessingState.loading;
          });
        }
      },
      onError: (Object e, StackTrace st) {
        if (mounted) {
          setState(() {
            _error = e.toString();
            _isPlaying = false;
          });
          debugPrint('[AUDIO] Player error: $e');
        }
      },
    );

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        if (mounted) {
          setState(() {
            _isPlaying = false;
            _currentPosition = Duration.zero;
          });
        }
        _player.seek(Duration.zero);
        _player.pause();
      }
    });

    // Устанавливаем источник
    try {
      if (widget.audioBytes != null) {
        await _player.setAudioSource(
          MemoryAudioSource(widget.audioBytes!),
          initialPosition: Duration.zero,
        );
      } else if (widget.audioUrl != null) {
        await _player.setUrl(widget.audioUrl!);
      }
      if (mounted) {
        setState(() {
          _totalDuration = _player.duration ?? widget.duration ?? Duration.zero;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Ошибка загрузки аудио';
        });
        debugPrint('[AUDIO] Setup error: $e');
      }
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlayPause() async {
    try {
      if (_isPlaying) {
        await _player.pause();
      } else {
        await _player.play();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Ошибка воспроизведения';
        });
      }
    }
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final fgColor = widget.isMe ? Colors.white : Colors.indigo;
    final bgColor = widget.isMe ? Colors.indigo[300] : Colors.grey[100];

    if (_error != null) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: Colors.red[300], size: 20),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _error!,
                style: TextStyle(color: Colors.red[300], fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Кнопка play/pause
              GestureDetector(
                onTap: _isLoading ? null : _togglePlayPause,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: widget.isMe ? Colors.white24 : Colors.indigo[50],
                    shape: BoxShape.circle,
                  ),
                  child: _isLoading
                      ? Padding(
                          padding: const EdgeInsets.all(8),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: fgColor,
                          ),
                        )
                      : Icon(
                          _isPlaying ? Icons.pause : Icons.play_arrow,
                          color: fgColor,
                          size: 22,
                        ),
                ),
              ),
              const SizedBox(width: 8),
              // Прогресс-бар
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SliderTheme(
                      data: SliderThemeData(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                        activeTrackColor: fgColor,
                        inactiveTrackColor: fgColor.withOpacity(0.3),
                        thumbColor: fgColor,
                      ),
                      child: Slider(
                        value: _totalDuration.inMilliseconds > 0
                            ? _currentPosition.inMilliseconds
                                .clamp(0, _totalDuration.inMilliseconds)
                                .toDouble()
                            : 0,
                        min: 0,
                        max: _totalDuration.inMilliseconds > 0
                            ? _totalDuration.inMilliseconds.toDouble()
                            : 1,
                        onChanged: (value) async {
                          await _player.seek(Duration(milliseconds: value.toInt()));
                        },
                      ),
                    ),
                    // Время
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(_currentPosition),
                          style: TextStyle(
                            color: widget.isMe ? Colors.white70 : Colors.grey[600],
                            fontSize: 11,
                          ),
                        ),
                        Text(
                          _formatDuration(_totalDuration),
                          style: TextStyle(
                            color: widget.isMe ? Colors.white70 : Colors.grey[600],
                            fontSize: 11,
                          ),
                        ),
                      ],
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

/// Аудио-источник из байтов в памяти (для just_audio)
class MemoryAudioSource extends StreamAudioSource {
  final Uint8List _bytes;

  MemoryAudioSource(this._bytes);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    start ??= 0;
    end ??= _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: end - start,
      offset: start,
      stream: Stream.value(_bytes.sublist(start, end)),
      contentType: 'audio/ogg',
    );
  }
}
