import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../services/call_service.dart';

/// Экран видеозвонка с локальным и удалённым видео
class CallScreen extends StatefulWidget {
  final CallSession callSession;
  final CallService callService;

  const CallScreen({
    super.key,
    required this.callSession,
    required this.callService,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  bool _renderersInitialized = false;

  @override
  void initState() {
    super.initState();
    _initRenderers();
  }

  Future<void> _initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    
    _renderersInitialized = true;
    
    // Привязываем рендереры к потокам
    if (widget.callSession.localStream != null) {
      _localRenderer.srcObject = widget.callSession.localStream;
    }
    if (widget.callSession.remoteStream != null) {
      _remoteRenderer.srcObject = widget.callSession.remoteStream;
    }
    
    // Слушаем обновления состояния звонка
    widget.callService.onCallStateChanged = (session) {
      if (mounted) {
        setState(() {
          if (session.remoteStream != null && _remoteRenderer.srcObject == null) {
            _remoteRenderer.srcObject = session.remoteStream;
          }
          if (session.localStream != null && _localRenderer.srcObject == null) {
            _localRenderer.srcObject = session.localStream;
          }
        });
      }
    };
    
    widget.callService.onCallEnded = () {
      if (mounted) {
        Navigator.of(context).pop();
      }
    };
    
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = d.inHours;
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.callSession;
    final isVideo = session.isVideo;
    final isConnected = session.state == CallState.kConnected;
    final isRinging = session.state == CallState.kRinging;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // === Удалённое видео (на весь экран) ===
            if (isVideo && _renderersInitialized && session.remoteStream != null)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  mirror: false,
                ),
              )
            else
              // Заглушка — аватар звонящего
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleAvatar(
                      radius: 60,
                      backgroundColor: Colors.indigo[700],
                      child: Text(
                        session.callerName.isNotEmpty
                            ? session.callerName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          fontSize: 40,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      session.callerName,
                      style: const TextStyle(
                        fontSize: 28,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildStateLabel(session),
                  ],
                ),
              ),

            // === Локальное видео (маленькое окно) ===
            if (isVideo && _renderersInitialized && session.localStream != null)
              Positioned(
                top: 80,
                right: 16,
                child: Container(
                  width: 120,
                  height: 160,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white24, width: 2),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: RTCVideoView(
                      _localRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      mirror: true,
                    ),
                  ),
                ),
              ),

            // === Верхняя панель ===
              Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black.withOpacity(0.7), Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            session.callerName,
                            style: const TextStyle(
                              fontSize: 20,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          _buildStateLabel(session),
                        ],
                      ),
                    ),
                    if (isConnected)
                      IconButton(
                        onPressed: () => widget.callService.toggleSpeaker(),
                        icon: Icon(
                          session.isSpeakerOn ? Icons.volume_up : Icons.volume_off,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // === Нижняя панель с кнопками ===
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Мут
                  _CallButton(
                    icon: session.isMuted ? Icons.mic_off : Icons.mic,
                    label: session.isMuted ? 'Вкл.' : 'Выкл.',
                    color: session.isMuted ? Colors.red : Colors.white,
                    bgColor: session.isMuted ? Colors.white24 : Colors.grey[800]!,
                    onPressed: () {
                      widget.callService.toggleMute();
                      setState(() {});
                    },
                  ),
                  // Камера
                  if (isVideo)
                    _CallButton(
                      icon: session.isCameraOff ? Icons.videocam_off : Icons.videocam,
                      label: session.isCameraOff ? 'Вкл.' : 'Выкл.',
                      color: session.isCameraOff ? Colors.red : Colors.white,
                      bgColor: session.isCameraOff ? Colors.white24 : Colors.grey[800]!,
                      onPressed: () {
                        widget.callService.toggleCamera();
                        setState(() {});
                      },
                    ),
                  // Завершить звонок
                  _CallButton(
                    icon: Icons.call_end,
                    label: 'Завершить',
                    color: Colors.white,
                    bgColor: Colors.red,
                    onPressed: () async {
                      await widget.callService.hangup();
                      if (mounted) Navigator.of(context).pop();
                    },
                    size: 64,
                  ),
                  // Входящий — принять/отклонить
                  if (isRinging && !session.isOutgoing) ...[
                    _CallButton(
                      icon: Icons.call,
                      label: 'Принять',
                      color: Colors.white,
                      bgColor: Colors.green,
                      onPressed: () async {
                        await widget.callService.answerCall();
                        setState(() {});
                      },
                      size: 64,
                    ),
                    _CallButton(
                      icon: Icons.call_end,
                      label: 'Отклонить',
                      color: Colors.white,
                      bgColor: Colors.red,
                      onPressed: () async {
                        await widget.callService.rejectCall();
                        if (mounted) Navigator.of(context).pop();
                      },
                      size: 64,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStateLabel(CallSession session) {
    String text;
    Color color;
    switch (session.state) {
      case CallState.kRinging:
        text = session.isOutgoing ? 'Вызов...' : 'Входящий звонок';
        color = Colors.orange;
        break;
      case CallState.kConnecting:
        text = 'Подключение...';
        color = Colors.orange;
        break;
      case CallState.kConnected:
        text = 'Подключено';
        color = Colors.green;
        break;
      case CallState.kEnded:
        text = 'Завершено';
        color = Colors.red;
        break;
    }
    return Text(
      text,
      style: TextStyle(color: color, fontSize: 14),
    );
  }
}

class _CallButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final Color bgColor;
  final VoidCallback onPressed;
  final double size;

  const _CallButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.bgColor,
    required this.onPressed,
    this.size = 52,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onPressed,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: bgColor,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: size * 0.45),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }
}
