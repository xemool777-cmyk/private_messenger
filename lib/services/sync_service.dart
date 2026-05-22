import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'keys_service.dart';
import 'notification_service.dart';

/// Сервис синхронизации: слушает onSync, обрабатывает уведомления, запрашивает ключи.
class SyncService {
  final Client _client;
  final KeysService _keys;
  StreamSubscription? _syncSub;
  bool _firstSyncDone = false;

  /// Текущая открытая комната (чтобы не показывать уведомление для неё)
  String? currentRoomId;

  SyncService(this._client, {required KeysService keys}) : _keys = keys;

  /// Начать слушать синхронизацию
  void startListening() {
    _startListeningForNotifications();
  }

  void _startListeningForNotifications() {
    final processedEventIds = <String>{};

    _syncSub = _client.onSync.stream.listen((syncUpdate) {
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

          final room = _client.getRoomById(roomId);
          if (room == null) continue;

          final isEncryptedRoom = room.getState('m.room.encryption') != null;

          String senderName = senderId.localpart ?? 'Неизвестный';
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
            roomName: room.getLocalizedDisplayname(),
            senderName: senderName,
            messageText: messageText,
          );
        }
      }
    });
  }

  void dispose() {
    _syncSub?.cancel();
  }
}
