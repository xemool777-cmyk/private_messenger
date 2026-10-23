/// Заглушка для не-web платформ. Реальная реализация в ringtone_service_web.dart.
class RingtoneService {
  static void unlockAudio() {}

  Future<void> playRingtone() async {}

  Future<void> stopRingtone() async {}

  Future<void> playRingback() async {}

  Future<void> stopRingback() async {}

  void setRemoteAudioVolume(double volume) {}
}
