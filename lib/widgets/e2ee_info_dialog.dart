import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../services/matrix_service.dart';

/// Диалог с информацией о шифровании и проверке устройств
class E2EEInfoDialog extends StatefulWidget {
  final MatrixService matrixService;
  final Room room;

  const E2EEInfoDialog({
    super.key,
    required this.matrixService,
    required this.room,
  });

  @override
  State<E2EEInfoDialog> createState() => _E2EEInfoDialogState();
}

class _E2EEInfoDialogState extends State<E2EEInfoDialog> {
  bool _isLoading = true;
  List<DeviceKeysInfo> _devices = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDeviceInfo();
  }

  Future<void> _loadDeviceInfo() async {
    final client = widget.matrixService.client;

    try {
      // Получаем список устройств участников комнаты
      final memberKeys = <DeviceKeysInfo>[];

      for (final member in widget.room.getParticipants()) {
        try {
          // matrix SDK 0.22.x: используем client.userDeviceKeys[userId]
          final keysList = client.userDeviceKeys[member.id];
          if (keysList != null) {
            for (final device in keysList.deviceKeys.values) {
              memberKeys.add(DeviceKeysInfo(
                userId: member.id,
                deviceId: device.deviceId ?? 'unknown',
                fingerprintKey: device.ed25519Key,
                identityKey: device.curve25519Key,
                isVerified: device.verified,
                displayName: device.deviceDisplayName ?? device.deviceId ?? 'Unknown',
              ));
            }
          }
        } catch (e) {
          debugPrint('[E2EE] Error loading keys for ${member.id}: $e');
        }
      }

      if (mounted) {
        setState(() {
          _devices = memberKeys;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  /// Экспорт ключей комнаты (полный дамп базы данных)
  Future<void> _exportKeys() async {
    try {
      final client = widget.matrixService.client;
      final encryption = client.encryption;
      if (encryption == null) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Экспорт ключей...")),
      );

      // Matrix SDK 0.22.x: используем client.exportDump()
      final dump = await client.exportDump();

      if (dump == null || dump.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Нет ключей для экспорта"),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (mounted) {
        // Показываем диалог с ключами
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Экспорт ключей"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Полный дамп базы данных шифрования. "
                    "Сохраните этот текст в безопасном месте — "
                    "он содержит все ключи для расшифровки сообщений.",
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: Scrollbar(
                      child: SingleChildScrollView(
                        child: SelectableText(
                          dump,
                          style: const TextStyle(fontSize: 9, fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Закрыть"),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка экспорта: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Перезапросить ключи расшифровки
  Future<void> _requestKeysAgain() async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Запрос ключей...")),
      );

      // Перезапрашиваем через room timeline
      final timeline = await widget.room.getTimeline();
      timeline.requestKeys();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Ключи запрошены! Подождите несколько секунд."),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Ошибка: $e"),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Форматирование fingerprint ключа — группировка по 4 символа
  String _formatFingerprint(String key) {
    final buffer = StringBuffer();
    for (int i = 0; i < key.length; i += 4) {
      if (i > 0) buffer.write(' ');
      final end = i + 4 > key.length ? key.length : i + 4;
      buffer.write(key.substring(i, end));
    }
    return buffer.toString();
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.matrixService.client;
    final isEncrypted = widget.room.getState('m.room.encryption') != null;
    final encryption = client.encryption;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            isEncrypted ? Icons.lock : Icons.lock_open,
            color: isEncrypted ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          const Text("Шифрование"),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Статус шифрования
                    _buildStatusCard(isEncrypted, client),
                    const SizedBox(height: 16),

                    // Ключи текущего устройства
                    if (encryption != null && client.encryptionEnabled) ...[
                      _buildKeyInfoCard(client),
                      const SizedBox(height: 16),
                    ],

                    // Список устройств
                    if (_devices.isNotEmpty) ...[
                      Text(
                        "Устройства участников",
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      ..._devices.map((d) => _buildDeviceCard(d)),
                    ],

                    // Ошибка
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red[50],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(color: Colors.red[700], fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      actions: [
        if (isEncrypted) ...[
          TextButton.icon(
            onPressed: _requestKeysAgain,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text("Запросить ключи"),
          ),
          TextButton.icon(
            onPressed: _exportKeys,
            icon: const Icon(Icons.download, size: 18),
            label: const Text("Экспорт ключей"),
          ),
        ],
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Закрыть"),
        ),
      ],
    );
  }

  Widget _buildStatusCard(bool isEncrypted, Client client) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isEncrypted ? Colors.green[50] : Colors.orange[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isEncrypted ? Colors.green[200]! : Colors.orange[200]!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isEncrypted ? Icons.verified_user : Icons.warning,
                color: isEncrypted ? Colors.green[700] : Colors.orange[700],
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                isEncrypted ? "Сквозное шифрование включено" : "Шифрование ВЫКЛЮЧЕНО",
                style: TextStyle(
                  color: isEncrypted ? Colors.green[700] : Colors.orange[700],
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          if (isEncrypted) ...[
            const SizedBox(height: 6),
            Text(
              "Алгоритм: Megolm (Olm)\n"
              "Ваши сообщения зашифрованы на вашем устройстве "
              "и могут быть прочитаны только участниками чата.",
              style: TextStyle(color: Colors.green[900], fontSize: 12),
            ),
          ] else ...[
            const SizedBox(height: 6),
            Text(
              "Сообщения в этом чате передаются в открытом виде. "
              "Включите шифрование для защиты переписки.",
              style: TextStyle(color: Colors.orange[900], fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildKeyInfoCard(Client client) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.vpn_key, color: Colors.blue[700], size: 20),
              const SizedBox(width: 8),
              Text(
                "Ключи вашего устройства",
                style: TextStyle(
                  color: Colors.blue[700],
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (client.identityKey != null) ...[
            Text(
              "Identity Key (Curve25519):",
              style: TextStyle(color: Colors.blue[900], fontSize: 11, fontWeight: FontWeight.w500),
            ),
            Text(
              _formatFingerprint(client.identityKey!),
              style: TextStyle(
                color: Colors.blue[900],
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ],
          const SizedBox(height: 4),
          if (client.fingerprintKey != null) ...[
            Text(
              "Fingerprint Key (Ed25519):",
              style: TextStyle(color: Colors.blue[900], fontSize: 11, fontWeight: FontWeight.w500),
            ),
            Text(
              _formatFingerprint(client.fingerprintKey!),
              style: TextStyle(
                color: Colors.blue[900],
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            "Сравните эти ключи с контактами для проверки подлинности.",
            style: TextStyle(color: Colors.blue[700], fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCard(DeviceKeysInfo device) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: device.isVerified ? Colors.green[50] : Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: device.isVerified ? Colors.green[200]! : Colors.grey[300]!,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                device.isVerified ? Icons.verified_user : Icons.phone_android,
                color: device.isVerified ? Colors.green[700] : Colors.grey[600],
                size: 18,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  device.displayName,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
              ),
              if (device.isVerified)
                Text(
                  "Проверено",
                  style: TextStyle(color: Colors.green[700], fontSize: 11),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            device.userId,
            style: TextStyle(color: Colors.grey[600], fontSize: 11),
          ),
          if (device.fingerprintKey != null) ...[
            const SizedBox(height: 2),
            Text(
              "Fingerprint: ${_formatFingerprint(device.fingerprintKey!)}",
              style: TextStyle(
                color: Colors.grey[700],
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Модель информации о ключах устройства
class DeviceKeysInfo {
  final String userId;
  final String deviceId;
  final String? fingerprintKey;
  final String? identityKey;
  final bool isVerified;
  final String displayName;

  DeviceKeysInfo({
    required this.userId,
    required this.deviceId,
    this.fingerprintKey,
    this.identityKey,
    required this.isVerified,
    required this.displayName,
  });
}
