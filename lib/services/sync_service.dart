import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'keys_service.dart';
import 'notification_service.dart';
import 'call_service.dart';

/// Сервис синхронизации: слушает onSync, обрабатывает уведомления, запрашивает ключи.
class SyncService {
  final Client _client;
  final KeysService _keys;
  final CallService? _callService;
  StreamSubscription? _syncSub;
  bool _firstSyncDone = false;

  /// Текущая открытая комната (чтобы не показывать уведомление для неё)
  String? currentRoomId;

  SyncService(this._client, {required KeysService keys, CallService? callService})
      : _keys = keys,
        _callService = callService;

  /// Начать слушать синхронизацию
  void startListening() {
    _startListeningForNotifications();
  }

  void _startListeningForNotifications() {
    final processedEventIds = <String>{};
    final processedInviteRoomIds = <String>{};

    _syncSub = _client.onSync.stream.listen(
      (syncUpdate) {
      try {
      // --- 1) Приглашения в комнаты ---
      final invitedRooms = syncUpdate.rooms?.invite;
      if (invitedRooms != null && invitedRooms.isNotEmpty) {
        for (final entry in invitedRooms.entries) {
          final roomId = entry.key;
          final inviteData = entry.value;

          // Извлекаем имя пригласившего из invite_state
          String inviterName = 'Неизвестный';
          final inviteState = inviteData.inviteState;
          if (inviteState != null) {
            for (final ev in inviteState) {
              if (ev.type == 'm.room.member' &&
                  ev.stateKey == _client.userID &&
                  ev.content['membership'] == 'invite') {
                final senderId = ev.senderId;
                if (senderId != null) {
                  inviterName = senderId.localpart ?? 'Неизвестный';
                }
                // Ищем displayname
                for (final se in inviteState) {
                  if (se.type == 'm.room.member' &&
                      se.stateKey == senderId &&
                      se.content['displayname'] != null) {
                    inviterName = se.content['displayname'] as String;
                    break;
                  }
                }
                break;
              }
            }
          }

          // Не спамим уведомлениями об одном и том же приглашении
          if (processedInviteRoomIds.contains(roomId)) continue;
          processedInviteRoomIds.add(roomId);

          // Проверяем, не в этой ли мы комнате сейчас
          if (currentRoomId == roomId) continue;

          debugPrint('[NOTIFY] Room invite: $roomId from $inviterName');

          NotificationService.instance.showMessageNotification(
            roomId: roomId,
            roomName: inviterName,
            senderName: inviterName,
            messageText: 'Приглашает вас в чат',
          );
        }
      }

      // --- 2) Сообщения в joined-комнатах ---
      final joinedRooms = syncUpdate.rooms?.join;
      if (joinedRooms == null || joinedRooms.isEmpty) return;

      // После первого sync — запрашиваем ключи для зашифрованных комнат
      if (!_firstSyncDone && _client.encryptionEnabled) {
        _firstSyncDone = true;
        _keys.requestKeysForEncryptedRooms();
      }

      for (final entry in joinedRooms.entries) {
        final roomId = entry.key;
        final roomData = entry.value;

        final timelineEvents = roomData.timeline?.events;
        if (timelineEvents == null || timelineEvents.isEmpty) continue;

        for (final matrixEvent in timelineEvents) {
          final eventType = matrixEvent.type;
          final senderId = matrixEvent.senderId;
          final eventId = matrixEvent.eventId;

          if (processedEventIds.contains(eventId)) continue;
          processedEventIds.add(eventId);

          if (processedEventIds.length > 200) {
            processedEventIds.remove(processedEventIds.first);
          }

          if (senderId == _client.userID) continue;
          if (eventType != 'm.room.message' && eventType != 'm.room.encrypted') continue;
          if (currentRoomId == roomId) continue;

          // Не показываем уведомления для комнаты с активным звонком —
          // события m.room.encrypted (call signaling) дают ложные «зашифрованное сообщение»
          if (_callService?.activeCallRoomId == roomId) continue;

          final room = _client.getRoomById(roomId);
          if (room == null) continue;

          String roomName;
          try {
            final dn = room.getLocalizedDisplayname();
            roomName = dn.isNotEmpty ? dn : (roomId.localpart ?? roomId);
          } catch (_) {
            roomName = roomId.localpart ?? roomId;
          }

          final isEncryptedRoom = room.getState('m.room.encryption') != null;

          String senderName = senderId?.localpart ?? 'Неизвестный';
          try {
            final memberEvent = room.getState('m.room.member', senderId);
            if (memberEvent != null) {
              final displayName = memberEvent.content['displayname'] as String?;
              if (displayName != null && displayName.isNotEmpty) {
                senderName = displayName;
              }
            }
          } catch (_) {}

          String messageText;

          if (eventType == 'm.room.encrypted') {
            messageText = 'Новое зашифрованное сообщение';
            debugPrint('[NOTIFY] Encrypted event in $roomId from $senderName');
          } else if (isEncryptedRoom && eventType == 'm.room.message') {
            final content = matrixEvent.content;
            final msgtype = content['msgtype'] as String? ?? '';
            final body = content['body'] as String? ?? '';

            if (msgtype == 'm.image') {
              messageText = 'Фото';
            } else if (msgtype == 'm.file') {
              messageText = 'Файл';
            } else if (msgtype == 'm.audio') {
              messageText = 'Аудио';
            } else if (msgtype == 'm.video') {
              messageText = 'Видео';
            } else {
              messageText = body.isNotEmpty ? body : 'Новое сообщение';
            }
            debugPrint('[NOTIFY] Decrypted message in $roomId from $senderName: $messageText');
          } else {
            final content = matrixEvent.content;
            final msgtype = content['msgtype'] as String? ?? '';
            final body = content['body'] as String? ?? '';

            if (msgtype == 'm.image') {
              messageText = 'Фото';
            } else if (msgtype == 'm.file') {
              messageText = 'Файл';
            } else if (msgtype == 'm.audio') {
              messageText = 'Аудио';
            } else if (msgtype == 'm.video') {
              messageText = 'Видео';
            } else {
              messageText = body.isNotEmpty ? body : 'Новое сообщение';
            }
            debugPrint('[NOTIFY] New message in $roomId from $senderName: $messageText');
          }

          NotificationService.instance.showMessageNotification(
            roomId: roomId,
            roomName: roomName,
            senderName: senderName,
            messageText: messageText,
          );
        }
      }
      } catch (e, st) {
        debugPrint('[SYNC-SERVICE] Error processing sync update: $e\n$st');
      }
    }, onError: (e) {
      debugPrint('[SYNC-SERVICE] Sync stream error: $e');
      // Переподписываемся через небольшую задержку
      Future.delayed(const Duration(seconds: 3), () {
        _syncSub?.cancel();
        _startListeningForNotifications();
      });
    });
  }

  void dispose() {
    _syncSub?.cancel();
  }
}
