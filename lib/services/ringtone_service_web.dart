import 'dart:html' as html;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

/// Web-реализация рингтона и ringback-тона.
class RingtoneService {
  html.AudioElement? _ringtone;
  html.AudioElement? _ringbackTone;
  static bool _audioUnlocked = false;

  /// Разблокировать аудио-контекст (вызвать при первом жесте пользователя).
  static void unlockAudio() {
    if (_audioUnlocked || !kIsWeb) return;
    _audioUnlocked = true;
    try {
      final audio = html.AudioElement(
          'data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA=');
      audio.volume = 0;
      audio.play().catchError((_) {});
    } catch (_) {}
  }

  Future<void> playRingtone() async {
    if (!kIsWeb) return;
    try {
      _ringtone?.pause();
      _ringtone = html.AudioElement(
          'data:audio/mp3;base64,SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU4Ljc2LjEwMAAAAAAAAAAAAAAA//tQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAASW5mbwAAAA8AAAAFAAADIQCcnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnP/7kMQAAHAAAQkAAAgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//tkMQAAHAAAQkAAAgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//uMRAAAHAAAlwAAFAAAACAAAcOHmDcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXAAABwcHBwd3d3eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eAHBwcHAAHBwcHAAAAA=');
      _ringtone!.loop = true;
      _ringtone!.volume = 1.0;
      await _ringtone!.play();
    } catch (e) {
      debugPrint('[CALL] Ringtone play error: $e');
    }
  }

  Future<void> stopRingtone() async {
    try {
      _ringtone?.pause();
      _ringtone?.currentTime = 0;
      _ringtone = null;
    } catch (_) {}
  }

  /// Ringback tone — играет звонящему пока ожидает ответа (P2.9).
  Future<void> playRingback() async {
    if (!kIsWeb) return;
    try {
      _ringbackTone?.pause();
      _ringbackTone = html.AudioElement(
          'data:audio/mp3;base64,SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU4Ljc2LjEwMAAAAAAAAAAAAAAA//tQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAASW5mbwAAAA8AAAAFAAADIQCcnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnP/7kMQAAHAAAQkAAAgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//tkMQAAHAAAQkAAAgAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//uMRAAAHAAAlwAAFAAAACAAAcOHmDcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXFxcXAAABwcHBwd3d3eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eHh4eAHBwcHAAHBwcHAAAAA=');
      _ringbackTone!.loop = true;
      _ringbackTone!.volume = 1.0;
      await _ringbackTone!.play();
    } catch (e) {
      debugPrint('[CALL] Ringback play error: $e');
    }
  }

  Future<void> stopRingback() async {
    try {
      _ringbackTone?.pause();
      _ringbackTone?.currentTime = 0;
      _ringbackTone = null;
    } catch (_) {}
  }

  /// Регулирует громкость удалённого аудио через HTML audio/video элементы.
  void setRemoteAudioVolume(double volume) {
    try {
      final elements = html.document.querySelectorAll('audio, video');
      for (final el in elements) {
        (el as html.MediaElement).volume = volume;
      }
    } catch (_) {}
  }
}
