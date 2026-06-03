import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:webrtc_interface/webrtc_interface.dart' hide Navigator;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../services/call_service.dart';

/// Полноэкранный UI аудио/видео звонка.
/// Входящие, исходящие и активные звонки.
class CallScreen extends StatefulWidget {
  final CallService callService;
  final CallSession callSession;
  const CallScreen({super.key, required this.callService, required this.callSession});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  CallState _callState = CallState.kFledgling;
  bool _isMuted = false;
  bool _isVideoMuted = false;
  bool _speakerOn = false;
  Duration _duration = Duration.zero;
  Timer? _timer;

  // Video renderers
  rtc.RTCVideoRenderer? _remoteRenderer;
  rtc.RTCVideoRenderer? _localRenderer;
  StreamSubscription<CallState>? _stateSub;
  StreamSubscription<WrappedMediaStream>? _streamAddSub;
  StreamSubscription<WrappedMediaStream>? _streamRemovedSub;

  @override
  void initState() {
    super.initState();
    _callState = widget.callSession.state;

    _stateSub = widget.callSession.onCallStateChanged.stream.listen((state) {
      if (!mounted) return;
      setState(() {
        _callState = state;
      });
      if (state == CallState.kConnected) {
        _startTimer();
      } else if (state == CallState.kEnded) {
        _timer?.cancel();
        // Автозакрытие через 2 сек
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            Navigator.of(context).pop();
          }
        });
      }
    });

    // Видео-стримы
    if (widget.callSession.type == CallType.kVideo) {
      _streamAddSub = widget.callSession.onStreamAdd.stream.listen(_onStreamAdd);
      _streamRemovedSub = widget.callSession.onStreamRemoved.stream.listen(_onStreamRemoved);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _stateSub?.cancel();
    _streamAddSub?.cancel();
    _streamRemovedSub?.cancel();
    _remoteRenderer?.dispose();
    _localRenderer?.dispose();
    super.dispose();
  }

  void _startTimer() {
    _duration = Duration.zero;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _duration += const Duration(seconds: 1);
      });
    });
  }

  Future<void> _onStreamAdd(WrappedMediaStream stream) async {
    if (!mounted) return;
    if (stream.isLocal()) {
      // Локальный стрим (наша камера)
      _localRenderer = rtc.RTCVideoRenderer();
      await _localRenderer!.initialize();
      _localRenderer!.srcObject = stream.stream!;
      setState(() {});
    } else {
      // Удалённый стрим (собеседник)
      _remoteRenderer = rtc.RTCVideoRenderer();
      await _remoteRenderer!.initialize();
      _remoteRenderer!.srcObject = stream.stream!;
      setState(() {});
    }
  }

  void _onStreamRemoved(WrappedMediaStream stream) {
    if (stream.isLocal()) {
      _localRenderer?.srcObject = null;
    } else {
      _remoteRenderer?.srcObject = null;
    }
    if (mounted) setState(() {});
  }

  String _formatDuration(Duration d) {
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  String get _displayName =>
      widget.callSession.remoteUser?.calcDisplayname() ?? 'Неизвестный';

  String _statusText() {
    switch (_callState) {
      case CallState.kFledgling:
        return widget.callSession.isOutgoing ? 'Вызов...' : 'Входящий звонок...';
      case CallState.kRinging:
        return widget.callSession.isOutgoing ? 'Гудки...' : 'Входящий звонок...';
      case CallState.kInviteSent:
      case CallState.kWaitLocalMedia:
      case CallState.kCreateOffer:
      case CallState.kCreateAnswer:
        return 'Соединение...';
      case CallState.kConnecting:
        return 'Соединение...';
      case CallState.kConnected:
        return _formatDuration(_duration);
      case CallState.kEnding:
        return 'Завершение...';
      case CallState.kEnded:
        return 'Звонок завершён';
    }
  }

  bool get _isIncoming =>
      _callState == CallState.kFledgling || _callState == CallState.kRinging;
  bool get _isActive => _callState == CallState.kConnected;
  bool get _hasEnded => _callState == CallState.kEnded;
  bool get _isVideo => widget.callSession.type == CallType.kVideo;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF1C1C1E),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 48),
              // Статус
              Text(
                _statusText(),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const SizedBox(height: 12),
              // Имя
              Text(
                _displayName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              // Тип звонка
              Text(
                _isVideo ? 'Видеозвонок' : 'Аудиозвонок',
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),

              // Центральная область
              Expanded(
                child: _isVideo && _isActive && _remoteRenderer != null
                    ? _buildVideoArea()
                    : _buildAvatarArea(),
              ),

              // Кнопки управления
              _buildControls(),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoArea() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Stack(
        children: [
          // Удалённое видео
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: rtc.RTCVideoView(
                _remoteRenderer!,
                objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
            ),
          ),
          // Локальное видео (PiP)
          if (_localRenderer != null && !_isVideoMuted)
            Positioned(
              right: 12,
              bottom: 12,
              child: Container(
                width: 120,
                height: 160,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white30, width: 2),
                ),
                clipBehavior: Clip.antiAlias,
                child: rtc.RTCVideoView(
                  _localRenderer!,
                  objectFit: rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  mirror: true,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAvatarArea() {
    final letter = _displayName.isNotEmpty ? _displayName[0].toUpperCase() : '?';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 50,
            backgroundColor: Colors.white,
            child: Text(
              letter,
              style: const TextStyle(
                color: Colors.indigo,
                fontSize: 40,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!_isActive && !_hasEnded)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white54,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    if (_hasEnded) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: _isIncoming ? _incomingButtons() : _activeButtons(),
      ),
    );
  }

  List<Widget> _incomingButtons() {
    return [
      // Отклонить
      _callButton(
        icon: Icons.call_end,
        color: Colors.red,
        size: 64,
        onPressed: () => widget.callService.hangup(),
      ),
      const SizedBox(width: 48),
      // Ответить
      _callButton(
        icon: Icons.phone,
        color: Colors.green,
        size: 64,
        onPressed: () => widget.callService.answer(),
      ),
    ];
  }

  List<Widget> _activeButtons() {
    final buttons = <Widget>[
      // Микрофон
      _callButton(
        icon: _isMuted ? Icons.mic_off : Icons.mic,
        color: _isMuted ? Colors.red : Colors.white24,
        iconColor: Colors.white,
        size: 56,
        onPressed: () async {
          await widget.callService.toggleMute();
          setState(() => _isMuted = !_isMuted);
        },
      ),
      // Громкая связь
      _callButton(
        icon: _speakerOn ? Icons.volume_up : Icons.volume_down_alt,
        color: _speakerOn ? Colors.indigo : Colors.white24,
        iconColor: Colors.white,
        size: 56,
        onPressed: () async {
          await widget.callService.toggleSpeakerphone();
          setState(() => _speakerOn = !_speakerOn);
        },
      ),
    ];

    // Кнопка видео
    if (_isVideo) {
      buttons.insert(1, _callButton(
        icon: _isVideoMuted ? Icons.videocam_off : Icons.videocam,
        color: _isVideoMuted ? Colors.red : Colors.white24,
        iconColor: Colors.white,
        size: 56,
        onPressed: () async {
          await widget.callService.toggleVideo();
          setState(() => _isVideoMuted = !_isVideoMuted);
        },
      ));
    }

    // Кнопка сброса
    buttons.add(
      _callButton(
        icon: Icons.call_end,
        color: Colors.red,
        size: 56,
        onPressed: () => widget.callService.hangup(),
      ),
    );

    return buttons;
  }

  Widget _callButton({
    required IconData icon,
    required Color color,
    double size = 56,
    Color iconColor = Colors.white,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: color,
      shape: const CircleBorder(),
      elevation: 4,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          child: Icon(icon, color: iconColor, size: size * 0.45),
        ),
      ),
    );
  }
}
