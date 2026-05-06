import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint, VoidCallback;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:matrix/matrix.dart';

/// Сервис видеозвонков через Matrix VoIP (WebRTC)
/// Обрабатывает сигналинг через m.call.* события и WebRTC соединение
class CallService {
  final Client client;
  
  // Активный звонок
  CallSession? _activeCall;
  CallSession? get activeCall => _activeCall;
  
  // Колбэки для UI
  VoidCallback? onIncomingCall;
  VoidCallback? onCallEnded;
  Function(CallSession)? onCallConnected;
  Function(CallSession)? onCallStateChanged;
  
  // Слушатели Matrix событий
  StreamSubscription? _eventSub;
  
  CallService(this.client) {
    _listenForCallEvents();
  }
  
  void _listenForCallEvents() {
    _eventSub = client.onSync.stream.listen((syncUpdate) {
      final joinedRooms = syncUpdate.rooms?.join;
      if (joinedRooms == null) return;
      
      for (final entry in joinedRooms.entries) {
        final roomId = entry.key;
        final roomData = entry.value;
        final events = roomData.timeline?.events;
        if (events == null) continue;
        
        for (final event in events) {
          _handleCallEvent(event, roomId);
        }
      }
    });
  }
  
  void _handleCallEvent(MatrixEvent event, String roomId) {
    final type = event.type;
    final content = event.content;
    final senderId = event.senderId;
    final callId = content['call_id'] as String?;
    
    if (callId == null) return;
    
    // Пропускаем свои же события
    if (senderId == client.userID) return;
    
    switch (type) {
      case 'm.call.invite':
        _handleIncomingInvite(roomId, callId, senderId!, content);
        break;
      case 'm.call.answer':
        _handleAnswer(callId, content);
        break;
      case 'm.call.candidates':
        _handleCandidates(callId, content);
        break;
      case 'm.call.hangup':
        _handleHangup(callId);
        break;
    }
  }
  
  /// Исходящий звонок
  Future<CallSession> startCall(String roomId, {bool video = false}) async {
    if (_activeCall != null) {
      throw Exception('Уже есть активный звонок');
    }
    
    final callId = 'call_${DateTime.now().millisecondsSinceEpoch}';
    final room = client.getRoomById(roomId);
    if (room == null) throw Exception('Комната не найдена');
    
    // Создаём WebRTC peer connection
    final peerConnection = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
    });
    
    final session = CallSession(
      callId: callId,
      roomId: roomId,
      isOutgoing: true,
      isVideo: video,
      peerConnection: peerConnection,
      localStream: null,
      remoteStream: null,
      state: CallState.kConnecting,
    );
    
    _activeCall = session;
    
    // Получаем медиа-поток
    try {
      final mediaConstraints = {
        'audio': true,
        'video': video ? {
          'mandatory': {
            'minWidth': '640',
            'minHeight': '480',
            'minFrameRate': '30',
          },
          'facingMode': 'user',
        } : false,
      };
      
      final localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
      session.localStream = localStream;
      
      localStream.getTracks().forEach((track) {
        peerConnection.addTrack(track, localStream);
      });
      
      onCallStateChanged?.call(session);
    } catch (e) {
      debugPrint('[CALL] Failed to get user media: $e');
      // Если не удалось получить медиа — продолжаем с аудио только
      try {
        final localStream = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
        session.localStream = localStream;
        session.isVideo = false;
        
        localStream.getTracks().forEach((track) {
          peerConnection.addTrack(track, localStream);
        });
        
        onCallStateChanged?.call(session);
      } catch (e2) {
        debugPrint('[CALL] Failed to get audio only: $e2');
        _endCall();
        rethrow;
      }
    }
    
    // Обработка ICE кандидатов
    peerConnection.onIceCandidate = (candidate) {
      _sendIceCandidates(roomId, callId, [candidate.toMap()]);
    };
    
    // Обработка удалённого потока
    peerConnection.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        session.remoteStream = event.streams[0];
        onCallStateChanged?.call(session);
      }
    };
    
    peerConnection.onIceConnectionState = (state) {
      debugPrint('[CALL] ICE state: $state');
      switch (state) {
        case RTCIceConnectionState.RTCIceConnectionStateConnected:
          session.state = CallState.kConnected;
          onCallConnected?.call(session);
          onCallStateChanged?.call(session);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
          session.state = CallState.kConnecting;
          onCallStateChanged?.call(session);
          break;
        case RTCIceConnectionState.RTCIceConnectionStateFailed:
          _endCall();
          break;
        default:
          break;
      }
    };
    
    // Создаём SDP offer
    final offer = await peerConnection.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': video,
    });
    await peerConnection.setLocalDescription(offer);
    
    // Отправляем m.call.invite
    await room.sendEvent({
      'msgtype': 'm.call.invite',
      'call_id': callId,
      'version': '1',
      'lifetime': 60000,
      'offer': {
        'type': 'offer',
        'sdp': offer.sdp,
      },
    }, type: 'm.call.invite');
    
    debugPrint('[CALL] Outgoing call sent: $callId');
    return session;
  }
  
  /// Обработка входящего приглашения
  void _handleIncomingInvite(String roomId, String callId, String senderId, Map<String, dynamic> content) {
    if (_activeCall != null) {
      debugPrint('[CALL] Already in a call, rejecting incoming');
      _sendHangup(roomId, callId);
      return;
    }
    
    final offer = content['offer'];
    if (offer == null) return;
    
    final session = CallSession(
      callId: callId,
      roomId: roomId,
      isOutgoing: false,
      isVideo: content.containsKey('invitee') ? false : true,
      peerConnection: null,
      localStream: null,
      remoteStream: null,
      callerId: senderId,
      offerSdp: offer['sdp'] as String?,
      state: CallState.kRinging,
    );
    
    _activeCall = session;
    debugPrint('[CALL] Incoming call from $senderId: $callId');
    onIncomingCall?.call();
  }
  
  /// Принять входящий звонок
  Future<void> answerCall() async {
    final session = _activeCall;
    if (session == null || session.isOutgoing || session.offerSdp == null) return;
    
    final room = client.getRoomById(session.roomId);
    if (room == null) return;
    
    try {
      // Создаём peer connection
      final peerConnection = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
        ],
      });
      session.peerConnection = peerConnection;
      
      // Получаем медиа-поток
      final localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': session.isVideo,
      });
      session.localStream = localStream;
      
      localStream.getTracks().forEach((track) {
        peerConnection.addTrack(track, localStream);
      });
      
      // Обработка ICE кандидатов
      peerConnection.onIceCandidate = (candidate) {
        _sendIceCandidates(session.roomId, session.callId, [candidate.toMap()]);
      };
      
      // Обработка удалённого потока
      peerConnection.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          session.remoteStream = event.streams[0];
          onCallStateChanged?.call(session);
        }
      };
      
      peerConnection.onIceConnectionState = (state) {
        debugPrint('[CALL] ICE state (incoming): $state');
        switch (state) {
          case RTCIceConnectionState.RTCIceConnectionStateConnected:
            session.state = CallState.kConnected;
            onCallConnected?.call(session);
            onCallStateChanged?.call(session);
            break;
          case RTCIceConnectionState.RTCIceConnectionStateFailed:
            _endCall();
            break;
          default:
            break;
        }
      };
      
      // Устанавливаем удалённый description (offer)
      await peerConnection.setRemoteDescription(
        RTCSessionDescription(session.offerSdp, 'offer'),
      );
      
      // Создаём answer
      final answer = await peerConnection.createAnswer();
      await peerConnection.setLocalDescription(answer);
      
      session.state = CallState.kConnecting;
      onCallStateChanged?.call(session);
      
      // Отправляем m.call.answer
      await room.sendEvent({
        'call_id': session.callId,
        'version': '1',
        'answer': {
          'type': 'answer',
          'sdp': answer.sdp,
        },
      }, type: 'm.call.answer');
      
      debugPrint('[CALL] Answer sent: ${session.callId}');
    } catch (e) {
      debugPrint('[CALL] Failed to answer: $e');
      _endCall();
    }
  }
  
  /// Отклонить звонок
  Future<void> rejectCall() async {
    final session = _activeCall;
    if (session == null) return;
    
    _sendHangup(session.roomId, session.callId);
    _endCall();
  }
  
  /// Обработка answer от удалённого участника
  void _handleAnswer(String callId, Map<String, dynamic> content) {
    if (_activeCall?.callId != callId) return;
    final session = _activeCall!;
    
    final answer = content['answer'];
    if (answer == null) return;
    
    session.peerConnection?.setRemoteDescription(
      RTCSessionDescription(answer['sdp'] as String, 'answer'),
    ).then((_) {
      debugPrint('[CALL] Remote description set (answer)');
    }).catchError((e) {
      debugPrint('[CALL] Error setting remote description: $e');
    });
  }
  
  /// Обработка ICE кандидатов
  void _handleCandidates(String callId, Map<String, dynamic> content) {
    if (_activeCall?.callId != callId) return;
    final session = _activeCall!;
    
    final candidates = content['candidates'] as List?;
    if (candidates == null) return;
    
    for (final candidateMap in candidates) {
      try {
        final candidate = RTCIceCandidate(
          candidateMap['candidate'] as String?,
          candidateMap['sdpMid'] as String?,
          candidateMap['sdpMLineIndex'] as int?,
        );
        session.peerConnection?.addCandidate(candidate);
      } catch (e) {
        debugPrint('[CALL] Error adding ICE candidate: $e');
      }
    }
  }
  
  /// Обработка hangup
  void _handleHangup(String callId) {
    if (_activeCall?.callId != callId) return;
    _endCall();
  }
  
  /// Завершить текущий звонок
  Future<void> hangup() async {
    final session = _activeCall;
    if (session == null) return;
    
    _sendHangup(session.roomId, session.callId);
    _endCall();
  }
  
  void _sendHangup(String roomId, String callId) async {
    final room = client.getRoomById(roomId);
    if (room == null) return;
    
    try {
      await room.sendEvent({
        'call_id': callId,
        'version': '1',
        'reason': 'user_hangup',
      }, type: 'm.call.hangup');
    } catch (e) {
      debugPrint('[CALL] Error sending hangup: $e');
    }
  }
  
  void _sendIceCandidates(String roomId, String callId, List<Map<String, dynamic>> candidates) async {
    final room = client.getRoomById(roomId);
    if (room == null) return;
    
    try {
      await room.sendEvent({
        'call_id': callId,
        'version': '1',
        'candidates': candidates,
      }, type: 'm.call.candidates');
    } catch (e) {
      debugPrint('[CALL] Error sending ICE candidates: $e');
    }
  }
  
  void _endCall() {
    final session = _activeCall;
    if (session == null) return;
    
    // Останавливаем медиа-потоки
    session.localStream?.getTracks().forEach((track) => track.stop());
    session.remoteStream?.getTracks().forEach((track) => track.stop());
    session.peerConnection?.close();
    
    _activeCall = null;
    onCallEnded?.call();
    onCallStateChanged?.call(session..state = CallState.kEnded);
    debugPrint('[CALL] Call ended');
  }
  
  /// Переключить микрофон
  void toggleMute() {
    final session = _activeCall;
    if (session == null) return;
    
    session.isMuted = !session.isMuted;
    session.localStream?.getAudioTracks().forEach((track) {
      track.enabled = !session.isMuted;
    });
    onCallStateChanged?.call(session);
  }
  
  /// Переключить камеру
  void toggleCamera() {
    final session = _activeCall;
    if (session == null) return;
    
    session.isCameraOff = !session.isCameraOff;
    session.localStream?.getVideoTracks().forEach((track) {
      track.enabled = !session.isCameraOff;
    });
    onCallStateChanged?.call(session);
  }
  
  /// Переключить на громкую связь / наушники
  void toggleSpeaker() {
    final session = _activeCall;
    if (session == null) return;
    
    session.isSpeakerOn = !session.isSpeakerOn;
    // На Android/iOS используем InCallManager
    if (!kIsWeb) {
      // TODO: InCallManager integration
    }
    onCallStateChanged?.call(session);
  }
  
  void dispose() {
    _eventSub?.cancel();
    _endCall();
  }
}

/// Состояние звонка
enum CallState {
  kRinging,      // Входящий звонок (звонок)
  kConnecting,   // Подключение
  kConnected,    // Разговор
  kEnded,        // Завершён
}

/// Сессия звонка
class CallSession {
  String callId;
  String roomId;
  bool isOutgoing;
  bool isVideo;
  RTCPeerConnection? peerConnection;
  MediaStream? localStream;
  MediaStream? remoteStream;
  String? callerId;
  String? offerSdp;
  CallState state;
  
  bool isMuted = false;
  bool isCameraOff = false;
  bool isSpeakerOn = false;
  
  CallSession({
    required this.callId,
    required this.roomId,
    required this.isOutgoing,
    required this.isVideo,
    required this.peerConnection,
    required this.localStream,
    required this.remoteStream,
    this.callerId,
    this.offerSdp,
    required this.state,
  });
  
  /// Имя звонящего
  String get callerName => callerId?.localpart ?? 'Неизвестный';
}
