import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
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
    _userId = client.userID ?? '';
    _displayName = client.getDisplayName() ?? _userId.localpart ?? '';
    _nameController.text = _displayName;
    _avatarUrl = client.getAvatarUrl();

    // Загружаем аватар если есть
    if (_avatarUrl != null) {
      _avatarBytes = await _downloadAvatar(_avatarUrl!);
    }

    if (mounted) setState(() { _isLoading = false; });
  }

  /// Скачать аватар через MSC3916 endpoint
  Future<Uint8List?> _downloadAvatar(Uri mxcUrl) async {
    final homeserver = widget.matrixService.client.homeserver;
    final accessToken = widget.matrixService.client.accessToken;
    if (homeserver == null || accessToken == null) return null;

    final serverName = mxcUrl.host;
    final mediaId = mxcUrl.pathSegments.join('/');

    final url = '${homeserver.scheme}://${homeserver.host}/_matrix/client/v1/media/download/$serverName/$mediaId';

    try {
      final httpClient = HttpClient();
      try {
        httpClient.badCertificateCallback = (cert, host, port) => true;
        final request = await httpClient.getUrl(Uri.parse(url));
        request.headers.set('Authorization', 'Bearer $accessToken');
        final response = await request.close();

        if (response.statusCode == 200) {
          final builder = await response.fold<BytesBuilder>(BytesBuilder(), (b, d) => b..add(d));
          return builder.toBytes();
        }
      } finally {
        httpClient.close();
      }
    } catch (e) {
      debugPrint('[PROFILE] Avatar download error: $e');
    }
    return null;
  }

  /// Выбрать новый аватар из галереи
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

  /// Сохранить профиль
  Future<void> _saveProfile() async {
    setState(() { _isSaving = true; });

    try {
      final client = widget.matrixService.client;
      bool changed = false;

      // Сохраняем отображаемое имя
      final newName = _nameController.text.trim();
      if (newName.isNotEmpty && newName != _displayName) {
        await client.setDisplayName(newName);
        _displayName = newName;
        changed = true;
      }

      // Сохраняем аватар если выбран новый
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
                        // Иконка редактирования
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
