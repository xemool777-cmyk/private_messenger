import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import '../config/app_config.dart';
import '../services/matrix_service.dart';
import '../services/keys_service.dart';

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

  // E2EE recovery key
  final _recoveryKeyController = TextEditingController();
  bool _isRestoring = false;
  bool _isResetting = false;
  bool _isSettingUp = false;
  ({bool initialized, bool connected})? _cryptoState;
  String? _cryptoError;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadCryptoState();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _recoveryKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    final client = widget.matrixService.client;
    _userId = widget.matrixService.userId;

    // Если userID пуст — пробуем синхронизацию чтобы обновить
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
      final profile = await client.getProfileFromUserId(_userId);
      _displayName = profile.displayName ?? _extractLocalpart(_userId);
      _avatarUrl = profile.avatarUrl;
    } catch (e) {
      debugPrint('[PROFILE] getProfileFromUserId failed: $e');
      _displayName = _extractLocalpart(_userId);
    }
    _nameController.text = _displayName;

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

  /// Выбрать новый аватар из галереи (web-safe: FilePicker вместо ImagePicker)
  Future<void> _pickAvatar() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null) return;

      setState(() { _newAvatarBytes = file.bytes; });
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
      if (_userId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Ошибка: не удалось определить пользователя"), backgroundColor: Colors.red),
        );
        return;
      }

      final client = widget.matrixService.client;
      bool changed = false;

      // Сохраняем отображаемое имя
      final newName = _nameController.text.trim();
      if (newName.isNotEmpty && newName != _displayName) {
        await client.setProfileField(client.userID!, 'displayname', {'displayname': newName});
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
                          const Text(
                            AppConfig.serverName,
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                       ],
                     ),
                   ),
                   const SizedBox(height: 16),

                    // === Шифрование E2EE ===
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: (_cryptoState != null && _cryptoState!.connected)
                            ? Colors.green[50]
                            : (_cryptoState != null && _cryptoState!.initialized)
                                ? Colors.orange[50]
                                : Colors.red[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: (_cryptoState != null && _cryptoState!.connected)
                              ? Colors.green[300]!
                              : (_cryptoState != null && _cryptoState!.initialized)
                                  ? Colors.orange[300]!
                                  : Colors.red[300]!,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                (_cryptoState != null && _cryptoState!.connected)
                                    ? Icons.lock
                                    : (_cryptoState != null && _cryptoState!.initialized)
                                        ? Icons.lock_open
                                        : Icons.lock_outline,
                                color: (_cryptoState != null && _cryptoState!.connected)
                                    ? Colors.green[700]
                                    : (_cryptoState != null && _cryptoState!.initialized)
                                        ? Colors.orange[700]
                                        : Colors.red[700],
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                "Сквозное шифрование",
                                style: TextStyle(
                                  color: Colors.grey[600],
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const Spacer(),
                              if (_cryptoState != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: _cryptoState!.connected
                                        ? Colors.green[100]
                                        : _cryptoState!.initialized
                                            ? Colors.orange[100]
                                            : Colors.red[100],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    _cryptoState!.connected
                                        ? "Подключено"
                                        : _cryptoState!.initialized
                                            ? "Новый ключ"
                                            : "Не настроено",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: _cryptoState!.connected
                                          ? Colors.green[800]
                                          : _cryptoState!.initialized
                                              ? Colors.orange[800]
                                              : Colors.red[800],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // ── Не настроено ──
                          if (_cryptoState != null && !_cryptoState!.initialized) ...[
                            Text(
                              "Кросс-подпись не настроена. Нажмите «Настроить» чтобы создать ключи шифрования.",
                              style: TextStyle(color: Colors.grey[700], fontSize: 11),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _isSettingUp ? null : _setupCryptoIdentity,
                                icon: _isSettingUp
                                    ? const SizedBox(width: 16, height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.security, size: 18),
                                label: Text(_isSettingUp ? 'Настройка...' : 'Настроить шифрование'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.indigo,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                              ),
                            ),
                          ],
                          // ── Новый ключ (initialized но не connected) ──
                          if (_cryptoState != null &&
                              _cryptoState!.initialized &&
                              !_cryptoState!.connected) ...[
                            Text(
                              "Устройство не подключено к кросс-подписи. "
                              "Введите ключ восстановления из другого устройства "
                              "(Профиль → «Ключ восстановления» → скопировать).",
                              style: TextStyle(color: Colors.grey[700], fontSize: 11),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: _recoveryKeyController,
                              decoration: InputDecoration(
                                hintText: 'EsTp ESYQ baBY APgP ...',
                                hintStyle: TextStyle(fontSize: 12, color: Colors.grey[400]),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                errorText: _cryptoError,
                                errorStyle: const TextStyle(fontSize: 11),
                              ),
                              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: _isRestoring ? null : _restoreCryptoIdentity,
                                icon: _isRestoring
                                    ? const SizedBox(width: 16, height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.vpn_key, size: 18),
                                label: Text(_isRestoring ? 'Восстановление...' : 'Восстановить ключ'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.orange,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                ),
                              ),
                            ),
                          ],
                          // ── Подключено ──
                          if (_cryptoState != null && _cryptoState!.connected) ...[
                            Text(
                              "Шифрование работает. Ваше устройство доверено.",
                              style: TextStyle(color: Colors.green[800], fontSize: 12),
                            ),
                            const SizedBox(height: 6),
                            // Ключ с кнопкой копирования
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    "Ключ восстановления: ${KeysService.savedRecoveryKey ?? '(сохранён)'}",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey[600],
                                      fontFamily: 'monospace',
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  height: 32,
                                  child: IconButton(
                                    onPressed: _copyRecoveryKey,
                                    icon: const Icon(Icons.copy, size: 16),
                                    tooltip: 'Скопировать ключ',
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    color: Colors.indigo[400],
                                  ),
                                ),
                              ],
                            ),
                          ],
                          // ── Кнопка сброса (всегда кроме «не настроено») ──
                          if (_cryptoState != null && _cryptoState!.initialized) ...[
                            const SizedBox(height: 12),
                            const Divider(height: 1),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: _isResetting ? null : _resetCryptoIdentity,
                                icon: _isResetting
                                    ? const SizedBox(width: 16, height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.refresh, size: 16, color: Colors.red),
                                label: Text(
                                  _isResetting ? 'Сброс...' : 'Сбросить шифрование',
                                  style: const TextStyle(fontSize: 12, color: Colors.red),
                                ),
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Colors.red),
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),

                  // === Кнопка выхода ===
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: _logout,
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

  /// Извлечь localpart из Matrix ID: @username:server → username
  String _extractLocalpart(String userId) {
    if (userId.startsWith('@') && userId.contains(':')) {
      return userId.substring(1, userId.indexOf(':'));
    }
    return userId;
  }

  /// Загрузить статус crypto identity с сервера
  Future<void> _loadCryptoState() async {
    try {
      final state = await widget.matrixService.checkCryptoIdentityState();
      if (mounted) setState(() { _cryptoState = state; });
    } catch (_) {}
  }

  /// Восстановить crypto identity по ключу восстановления
  Future<void> _restoreCryptoIdentity() async {
    final key = _recoveryKeyController.text.trim();
    if (key.isEmpty) {
      setState(() { _cryptoError = 'Введите ключ восстановления'; });
      return;
    }

    setState(() { _isRestoring = true; _cryptoError = null; });

    try {
      final ok = await widget.matrixService.restoreCryptoIdentity(key);
      if (mounted) {
        if (ok) {
          setState(() { _cryptoError = null; _isRestoring = false; });
          await _loadCryptoState();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Ключ восстановлен! E2EE готово.'),
                backgroundColor: Colors.green),
          );
        } else {
          setState(() { _cryptoError = 'Неверный ключ восстановления'; _isRestoring = false; });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() { _cryptoError = 'Ошибка: $e'; _isRestoring = false; });
      }
    }
  }

  /// Запросить пароль, если не сохранён (нужен для UIA)
  Future<bool> _ensurePassword() async {
    if (KeysService.hasPassword) return true;

    final controller = TextEditingController();
    final obscure = ValueNotifier<bool>(true);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text("Пароль"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Для сброса шифрования нужен пароль от аккаунта Matrix.",
                  style: TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                obscureText: obscure.value,
                decoration: InputDecoration(
                  labelText: 'Пароль',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(obscure.value ? Icons.visibility_off : Icons.visibility),
                    onPressed: () {
                      setDialogState(() {});
                      obscure.value = !obscure.value;
                    },
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Отмена")),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text("OK"),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    obscure.dispose();

    if (result != null && result.isNotEmpty) {
      KeysService.setPassword(result);
      return true;
    }
    return false;
  }

  /// Настроить crypto identity (первое устройство)
  Future<void> _setupCryptoIdentity() async {
    // Запрашиваем пароль для UIA (если ещё не сохранён)
    if (!await _ensurePassword()) return;

    setState(() { _isSettingUp = true; _cryptoError = null; });

    try {
      final ok = await widget.matrixService.keys.setupCryptoIdentity();
      if (mounted) {
        setState(() { _isSettingUp = false; });
        await _loadCryptoState();
        if (ok) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Шифрование настроено! Скопируйте ключ восстановления.'),
                backgroundColor: Colors.green),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось настроить шифрование.'),
                backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() { _isSettingUp = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Сбросить и пересоздать кросс-подпись
  Future<void> _resetCryptoIdentity() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Сбросить шифрование"),
        content: const Text(
          "Будут удалены текущие ключи шифрования и созданы новые. "
          "Все устройства должны будут заново ввести ключ восстановления. "
          "Продолжить?",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Отмена")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Сбросить", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    // Запрашиваем пароль для UIA (если ещё не сохранён)
    if (!await _ensurePassword()) return;

    setState(() { _isResetting = true; _cryptoError = null; });

    try {
      final newKey = await widget.matrixService.resetCryptoIdentity();
      if (mounted) {
        setState(() { _isResetting = false; });
        await _loadCryptoState();
        if (newKey != null) {
          // Показываем новый ключ в диалоге с кнопкой копирования
          await showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Row(children: [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Text("Шифрование сброшено"),
              ]),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Новый ключ восстановления (скопируйте его):",
                      style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      newKey,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: newKey));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Ключ скопирован!'),
                          backgroundColor: Colors.green),
                    );
                    Navigator.pop(ctx);
                  },
                  child: const Text("Скопировать и закрыть"),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Закрыть"),
                ),
              ],
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось сбросить шифрование.'),
                backgroundColor: Colors.red),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() { _isResetting = false; });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Скопировать ключ восстановления в буфер обмена
  void _copyRecoveryKey() {
    final key = KeysService.savedRecoveryKey;
    if (key == null || key.isEmpty) return;
    Clipboard.setData(ClipboardData(text: key));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ключ скопирован в буфер обмена!'),
          backgroundColor: Colors.green),
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

  Future<void> _logout() async {
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
