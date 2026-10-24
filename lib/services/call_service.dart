import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:webrtc_interface/webrtc_interface.dart' hide Navigator;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../screens/call_screen.dart';
import 'notification_service.dart';
import 'ringtone_service.dart';

/// Сервис аудио/видео звонков.
/// Реализует WebRTCDelegate, управляет VoIP-сессиями, рингтоном и UI вызова.
class CallService implements WebRTCDelegate {
  final Client _client;
  VoIP? _voip;
  StreamSubscription<CallState>? _callStateSub;

  /// Текущий активный CallSession (null если нет звонка)
  CallSession? _currentCall;
  CallSession? get currentCall => _currentCall;

  /// Состояние текущего звонка
  CallState _callState = CallState.kFledgling;
  CallState get callState => _callState;

  /// ID комнаты текущего активного звонка (null если нет звонка)
  String? get activeCallRoomId => _currentCall?.room.id;

  /// Stream состояний для UI
  final _callStateController = StreamController<CallState>.broadcast();
  Stream<CallState> get onCallStateChanged => _callStateController.stream;

  // ---- Ringtone / Ringback ----
  final RingtoneService _ringtoneService = RingtoneService();

  CallService(this._client);

  /// Инициализация VoIP модуля
  void init() {
    _voip = VoIP(_client, this);
  }

  /// Разблокировать аудио-контекст (вызвать при первом жесте пользователя)
  static void unlockAudio() {
    RingtoneService.unlockAudio();
  }

  // ==================== WebRTCDelegate ====================

  @override
  MediaDevices get mediaDevices => rtc.navigator.mediaDevices;

  @override
  Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const {},
  ]) {
    return rtc.createPeerConnection(configuration, constraints);
  }

  @override
  Future<void> playRingtone() => _ringtoneService.playRingtone();

  @override
  Future<void> stopRingtone() => _ringtoneService.stopRingtone();

  /// Ringback tone — играет звонящему пока ожидает ответа (P2.9)
  Future<void> playRingback() => _ringtoneService.playRingback();

  Future<void> stopRingback() => _ringtoneService.stopRingback();

  @override
  Future<void> registerListeners(CallSession session) async {
    _currentCall = session;

    _callStateSub?.cancel();
    _callStateSub = session.onCallStateChanged.stream.listen((state) {
      _callState = state;
      _callStateController.add(state);
      debugPrint('[CALL] State: $state');

      if (state == CallState.kConnected) {
        stopRingtone().catchError((_) {});
        stopRingback().catchError((_) {});
      } else if (state == CallState.kEnded) {
        stopRingtone().catchError((_) {});
        stopRingback().catchError((_) {});
        _cleanupCall();
      }
    });
  }

  @override
  Future<void> handleNewCall(CallSession session) async {
    debugPrint(
        '[CALL] Incoming call from ${session.remoteUser?.calcDisplayname()}');
    _currentCall = session;

    // Слушаем состояние (на случай пропущенного registerListeners)
    _callStateSub?.cancel();
    _callStateSub = session.onCallStateChanged.stream.listen((state) {
      _callState = state;
      _callStateController.add(state);
      if (state == CallState.kEnded) {
        stopRingtone().catchError((_) {});
        stopRingback().catchError((_) {});
        _cleanupCall();
        _popCallScreen();
      }
    });

    await playRingtone();

    // Показываем экран входящего звонка
    _pushCallScreen(session);
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    debugPrint('[CALL] Call ended');
    stopRingtone().catchError((_) {});
    stopRingback().catchError((_) {});
    _cleanupCall();
    _popCallScreen();
  }

  @override
  Future<void> handleMissedCall(CallSession session) async {
    debugPrint('[CALL] Missed call');
    stopRingtone().catchError((_) {});

    final context = navigatorKey.currentContext;
    if (context != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Пропущенный звонок от ${session.remoteUser?.calcDisplayname() ?? "неизвестного"}',
          ),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {}
  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {}

  @override
  bool get isWeb => kIsWeb;

  @override
  bool get canHandleNewCall {
    if (_currentCall == null) return true;
    return _currentCall!.state != CallState.kConnected;
  }

  @override
  EncryptionKeyProvider? get keyProvider => null;

  // ==================== Public API ====================

  /// Начать исходящий звонок
  Future<CallSession?> inviteToCall(Room room, CallType type) async {
    if (_voip == null) {
      debugPrint('[CALL] VoIP not initialized');
      return null;
    }

    try {
      final session = await _voip!.inviteToCall(room, type);
      _currentCall = session;

      // Играем гудки для звонящего (ringback)
      if (session.isOutgoing) {
        playRingback().catchError((_) {});
      }

      // Слушаем состояние
      _callStateSub?.cancel();
      _callStateSub = session.onCallStateChanged.stream.listen((state) {
        _callState = state;
        _callStateController.add(state);
        if (state == CallState.kEnded) {
          stopRingtone().catchError((_) {});
          stopRingback().catchError((_) {});
          _cleanupCall();
          _popCallScreen();
        }
      });

      // Показываем экран звонка
      _pushCallScreen(session);

      return session;
    } catch (e) {
      debugPrint('[CALL] inviteToCall error: $e');
      return null;
    }
  }

  /// Ответить на входящий звонок
  Future<void> answer() async {
    final call = _currentCall;
    if (call == null) return;
    try {
      await stopRingtone();
      await call.answer();
    } catch (e) {
      debugPrint('[CALL] Answer error: $e');
    }
  }

  /// Повесить трубку
  Future<void> hangup() async {
    final call = _currentCall;
    if (call == null) return;
    try {
      await stopRingtone();
      await stopRingback();
      await call.hangup(reason: CallErrorCode.userHangup);
    } catch (e) {
      debugPrint('[CALL] Hangup error: $e');
    }
    _cleanupCall();
    _popCallScreen();
  }

  /// Включить/выключить микрофон
  Future<void> toggleMute() async {
    final call = _currentCall;
    if (call == null) return;
    try {
      final muted = !call.isMicrophoneMuted;
      await call.setMicrophoneMuted(muted);
    } catch (e) {
      debugPrint('[CALL] Toggle mute error: $e');
    }
  }

  /// Включить/выключить видео
  Future<void> toggleVideo() async {
    final call = _currentCall;
    if (call == null) return;
    try {
      final videoMuted = !call.isLocalVideoMuted;
      await call.setLocalVideoMuted(videoMuted);
    } catch (e) {
      debugPrint('[CALL] Toggle video error: $e');
    }
  }

  /// Переключить громкую связь (speakerphone) — P2.9
  Future<void> toggleSpeakerphone() async {
    final call = _currentCall;
    if (call == null) return;
    try {
      _speakerphoneOn = !_speakerphoneOn;
      // На web используем аудио-элементы для управления громкостью
      if (kIsWeb) {
        _setRemoteAudioVolume(_speakerphoneOn ? 1.0 : 0.5);
      }
    } catch (e) {
      debugPrint('[CALL] Toggle speakerphone error: $e');
    }
  }

  /// Громкая связь включена?
  bool _speakerphoneOn = false;
  bool get isSpeakerphoneOn => _speakerphoneOn;

  /// Регулирует громкость удалённого аудио через HTML audio/video элементы
  void _setRemoteAudioVolume(double volume) {
    _ringtoneService.setRemoteAudioVolume(volume);
  }

  // ==================== Internal ====================

  void _pushCallScreen(CallSession session) {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(callService: this, callSession: session),
        fullscreenDialog: true,
      ),
    );
  }

  void _popCallScreen() {
    final context = navigatorKey.currentContext;
    if (context == null) return;
    final nav = Navigator.of(context);
    // Проверяем, что верхний экран — это CallScreen, а не что-то другое
    if (nav.canPop()) {
      try {
        nav.pop();
      } catch (_) {}
    }
  }

  void _cleanupCall() {
    _callStateSub?.cancel();
    _callStateSub = null;
    _currentCall = null;
    _callState = CallState.kFledgling;
  }

  void dispose() {
    _cleanupCall();
    stopRingtone().catchError((_) {});
    _callStateController.close();
  }
}
