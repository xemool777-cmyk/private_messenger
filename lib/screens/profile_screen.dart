import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import '../services/matrix_service.dart';

class ProfileScreen extends StatefulWidget {
  final MatrixService matrixService;
  const ProfileScreen({super.key, required this.matrixService});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _isLoading = true;
  bool _isSaving = false;
  String _displayName = '';
  String _userId = '';
  Uri? _avatarUrl;
  Uint8List? _avatarBytes;
  Uint8List? _newAvatarBytes;
  final _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final client = widget.matrixService.client;
    _userId = widget.matrixService.userId;

    if (_userId.isEmpty) {
      debugPrint('[PROFILE] userID is null, trying sync...');
      try {
        await client.oneShotSync();
        _userId = widget.matrixService.userId;
      } catch (_) {}
    }

    if (_userId.isEmpty) {
      debugPrint('[PROFILE] userID still null, cannot load profile');
      if (mounted) setState(() { _isLoading = false; });
      return;
    }

    try {
      _displayName = await client.getDisplayName(_userId) ?? _extractLocalpart(_userId);
    } catch (e) {
      debugPrint('[PROFILE] getDisplayName failed: $e');
      _displayName = _extractLocalpart(_userId);
    }
    _nameController.text = _displayName;

    try {
      _avatarUrl = await client.getAvatarUrl(_userId);
    } catch (e) {
      debugPrint('[PROFILE] getAvatarUrl failed: $e');
    }

    if (_avatarUrl != null) {
      _avatarBytes = await _downloadAvatar(_avatarUrl!);
    }

    if (mounted) setState(() { _isLoading = false; });
  }

  Future<Uint8List?> _downloadAvatar(Uri mxcUrl) async {
    final homeserver = widget.matrixService.client.homeserver;
    final accessToken = widget.matrixService.client.accessToken;
    if (homeserver == null || accessToken == null) return null;

    final serverName = mxcUrl.host;
    final mediaId = mxcUrl.pathSegments.join('/');
    final url = '${homeserver.scheme}://${homeserver.host}/_matrix/client/v1/media/download/$serverName/$mediaId';

    try {
      final response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode == 200) {
        return Uint8List.fromList(response.bodyBytes);
      }
    } catch (e) {
      debugPrint('[PROFILE] Avatar download error: $e');
    }
    return null;
  }

  Future<void> _pickAvatar() async {
    try {
      final picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
      );
      if (image == null) return;

      final bytes = await image.readAsBytes();
      setState(() { _newAvatarBytes = bytes; });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка: $e"), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _saveProfile() async {
    setState(() { _isSaving = true; });

    try {
      if (_userId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Ошибка: не удалось определить пользователя"), backgroundColor: Colors.red),
        );
        return;
      }

      final client = widget.matrixService.client;
      bool changed = false;

      final newName = _nameController.text.trim();
      if (newName.isNotEmpty && newName != _displayName) {
        await client.setDisplayName(_userId, newName);
        _displayName = newName;
        changed = true;
      }

      if (_newAvatarBytes != null) {
        final matrixFile = MatrixImageFile(
          bytes: _newAvatarBytes!,
          name: 'avatar.jpg',
          mimeType: 'image/jpeg',
        );
        await client.setAvatar(matrixFile);
        _avatarBytes = _newAvatarBytes;
        _newAvatarBytes = null;
        changed = true;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(changed ? "Профиль обновлён!" : "Нет изменений"),
            backgroundColor: changed ? Colors.green : Colors.grey,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка сохранения: $e"), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() { _isSaving = false; });
    }
  }

  /// Показать детали E2EE — устройства и ключи
  Future<void> _showE2EEDetails() async {
    final client = widget.matrixService.client;
    
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Icon(
              client.encryptionEnabled ? Icons.lock : Icons.lock_open,
              color: client.encryptionEnabled ? Colors.green : Colors.red,
            ),
            const SizedBox(width: 8),
            const Text("Шифрование E2EE"),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Статус
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: client.encryptionEnabled ? Colors.green[50] : Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        client.encryptionEnabled ? Icons.verified_user : Icons.warning,
                        color: client.encryptionEnabled ? Colors.green[700] : Colors.red[700],
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          client.encryptionEnabled
                              ? "Сквозное шифрование активно"
                              : "Шифрование не включено",
                          style: TextStyle(
                            color: client.encryptionEnabled ? Colors.green[700] : Colors.red[700],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Ключи устройства
                if (client.encryptionEnabled) ...[
                  const Text(
                    "Ключи вашего устройства:",
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  if (client.identityKey != null) ...[
                    Text("Identity Key (Curve25519):", style: TextStyle(color: Colors.grey[700], fontSize: 11)),
                    SelectableText(
                      client.identityKey!,
                      style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (client.fingerprintKey != null) ...[
                    Text("Fingerprint Key (Ed25519):", style: TextStyle(color: Colors.grey[700], fontSize: 11)),
                    SelectableText(
                      client.fingerprintKey!,
                      style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    "Сравните эти ключи с собеседником для проверки подлинности. "
                    "Если ключи совпадают — связь защищена от перехвата.",
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                ],

                // Устройства
                FutureBuilder<List<DeviceKeys>>(
                  future: widget.matrixService.getMyDevices(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    
                    final devices = snapshot.data ?? [];
                    if (devices.isEmpty) {
                      return Text(
                        "Не удалось загрузить список устройств",
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      );
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Ваши устройства (${devices.length}):",
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        ...devices.map((device) => Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: device.deviceId == client.deviceID
                                ? Colors.blue[50]
                                : Colors.grey[50],
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: device.deviceId == client.deviceID
                                  ? Colors.blue[200]!
                                  : Colors.grey[300]!,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                device.deviceId == client.deviceID
                                    ? Icons.phone_android
                                    : Icons.devices,
                                size: 18,
                                color: device.deviceId == client.deviceID
                                    ? Colors.blue
                                    : Colors.grey[600],
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      device.deviceDisplayName ?? device.deviceId,
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                                    ),
                                    Text(
                                      device.deviceId,
                                      style: TextStyle(fontSize: 10, color: Colors.grey[500], fontFamily: 'monospace'),
                                    ),
                                  ],
                                ),
                              ),
                              if (device.deviceId == client.deviceID)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.blue[100],
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    "Текущее",
                                    style: TextStyle(fontSize: 10, color: Colors.blue),
                                  ),
                                ),
                              if (device.verified)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.green[100],
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    "Проверено",
                                    style: TextStyle(fontSize: 10, color: Colors.green),
                                  ),
                                ),
                            ],
                          ),
                        )),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text("Закрыть"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final client = widget.matrixService.client;
    final displayAvatar = _newAvatarBytes ?? _avatarBytes;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Профиль"),
        actions: [
          if (!_isLoading)
            TextButton(
              onPressed: _isSaving ? null : _saveProfile,
              child: _isSaving
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text("Сохранить", style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // === Аватар ===
                  GestureDetector(
                    onTap: _pickAvatar,
                    child: Stack(
                      children: [
                        Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.indigo[100],
                            border: Border.all(color: Colors.indigo, width: 3),
                          ),
                          child: ClipOval(
                            child: displayAvatar != null
                                ? Image.memory(
                                    displayAvatar,
                                    fit: BoxFit.cover,
                                    width: 140,
                                    height: 140,
                                    errorBuilder: (_, __, ___) => _avatarPlaceholder(),
                                  )
                                : _avatarPlaceholder(),
                          ),
                        ),
                        Positioned(
                          bottom: 4,
                          right: 4,
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.indigo,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Нажмите чтобы сменить аватар",
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                  const SizedBox(height: 32),

                  // === User ID ===
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.badge, color: Colors.grey[600], size: 18),
                            const SizedBox(width: 8),
                            Text(
                              "Matrix ID",
                              style: TextStyle(color: Colors.grey[600], fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        SelectableText(
                          _userId,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // === Отображаемое имя ===
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: "Отображаемое имя",
                      prefixIcon: const Icon(Icons.person),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: Colors.grey[300]!),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // === Информация о сервере ===
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.dns, color: Colors.grey[600], size: 18),
                            const SizedBox(width: 8),
                            Text(
                              "Сервер",
                              style: TextStyle(color: Colors.grey[600], fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          MatrixService.serverName,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // === E2EE Информация ===
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: client.encryptionEnabled ? Colors.green[50] : Colors.red[50],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: client.encryptionEnabled ? Colors.green[200]! : Colors.red[200]!,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              client.encryptionEnabled ? Icons.lock : Icons.lock_open,
                              color: client.encryptionEnabled ? Colors.green[700] : Colors.red[700],
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              client.encryptionEnabled ? "Шифрование активно" : "Шифрование выключено",
                              style: TextStyle(
                                color: client.encryptionEnabled ? Colors.green[700] : Colors.red[700],
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                        if (client.encryptionEnabled && client.fingerprintKey != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            "Fingerprint Key:",
                            style: TextStyle(color: Colors.green[900], fontSize: 11),
                          ),
                          SelectableText(
                            client.fingerprintKey!,
                            style: TextStyle(
                              color: Colors.green[900],
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _showE2EEDetails,
                            icon: Icon(
                              Icons.vpn_key,
                              size: 16,
                              color: client.encryptionEnabled ? Colors.green[700] : Colors.red[700],
                            ),
                            label: Text(
                              "Устройства и ключи",
                              style: TextStyle(
                                color: client.encryptionEnabled ? Colors.green[700] : Colors.red[700],
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: client.encryptionEnabled ? Colors.green[300]! : Colors.red[300]!,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  // === Кнопка выхода ===
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => _logout(context),
                      icon: const Icon(Icons.exit_to_app, color: Colors.red),
                      label: const Text("Выйти из аккаунта", style: TextStyle(color: Colors.red)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: Colors.red),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  String _extractLocalpart(String userId) {
    if (userId.startsWith('@') && userId.contains(':')) {
      return userId.substring(1, userId.indexOf(':'));
    }
    return userId;
  }

  Widget _avatarPlaceholder() {
    final letter = _displayName.isNotEmpty ? _displayName[0].toUpperCase() : '?';
    return Center(
      child: Text(
        letter,
        style: const TextStyle(
          fontSize: 52,
          fontWeight: FontWeight.bold,
          color: Colors.indigo,
        ),
      ),
    );
  }

  void _logout(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Выход"),
        content: const Text("Вы уверены, что хотите выйти из аккаунта?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Отмена"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Выйти", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await widget.matrixService.logout();
      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, '/', (route) => false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Ошибка выхода: $e")),
        );
      }
    }
  }
}
