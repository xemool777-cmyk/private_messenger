import 'package:flutter/material.dart';
import '../services/matrix_service.dart';
import 'chats_screen.dart';

class LoginPage extends StatefulWidget {
  final MatrixService matrixService;
  const LoginPage({super.key, required this.matrixService});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tryResumeSession();
  }

  /// Попытка восстановить предыдущую сессию
  Future<void> _tryResumeSession() async {
    if (widget.matrixService.isLogged) {
      setState(() { _isLoading = true; });
      try {
        await widget.matrixService.resumeSession();
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => ChatsScreen(matrixService: widget.matrixService)),
          );
          _checkCryptoAndPrompt();
        }
      } catch (e) {
        // Сессия протухла — просто показываем логин
        debugPrint('Session resume failed: $e');
      } finally {
        if (mounted) setState(() { _isLoading = false; });
      }
    }
  }

  Future<void> _loginOrRegister() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (username.isEmpty || password.isEmpty) {
      setState(() { _error = 'Введите логин и пароль'; });
      return;
    }

    setState(() { _isLoading = true; _error = null; });

    try {
      await widget.matrixService.login(username, password);

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => ChatsScreen(matrixService: widget.matrixService)),
        );
        _checkCryptoAndPrompt();
      }
    } catch (e) {
      debugPrint('[LOGIN] Error: $e');
      String errorMsg = 'Ошибка подключения';
      if (e.toString().contains('M_FORBIDDEN')) {
        errorMsg = 'Неверный логин или пароль';
      } else if (e.toString().contains('Connection') || e.toString().contains('SocketException')) {
        errorMsg = 'Нет связи с сервером. Проверьте интернет.';
      } else if (e.toString().contains('HttpException') || e.toString().contains('http error')) {
        errorMsg = 'Сервер не отвечает. Попробуйте позже.';
      } else {
        errorMsg = 'Ошибка: $e';
      }
      setState(() { _error = errorMsg; });
    } finally {
      if (mounted) setState(() { _isLoading = false; });
    }
  }

  /// Проверить crypto identity и показать диалог настройки/восстановления
  Future<void> _checkCryptoAndPrompt() async {
    // Задержка 3с — даём sync'у подтянуть accountData
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;

    try {
      final state = await widget.matrixService.checkCryptoIdentityState();
      if (state == null) return;  // encryption not enabled at all
      if (state.connected) return; // already connected

      // Показываем диалог
      final recoveryKeyController = TextEditingController();
      String? dialogError;

      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              final needsSetup = !state.initialized;
              return AlertDialog(
                title: Row(children: [
                  Icon(needsSetup ? Icons.security : Icons.vpn_key,
                      color: Colors.orange[700]),
                  const SizedBox(width: 10),
                  Text(needsSetup ? "Настройка шифрования" : "Восстановление шифрования"),
                ]),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        needsSetup
                            ? "Шифрование сквозное (end-to-end) ещё не настроено. "
                                "Нажмите «Настроить» чтобы создать ключи. "
                                "После настройки сохраните ключ восстановления — "
                                "он понадобится на других устройствах."
                            : "Ваше устройство не подключено к кросс-подписи. "
                                "Чтобы сообщения расшифровывались, введите ключ восстановления "
                                "из другого устройства.",
                        style: const TextStyle(fontSize: 13),
                      ),
                      if (needsSetup) ...[
                        const SizedBox(height: 10),
                        Text(
                          "Это первое устройство для этого аккаунта. "
                          "Ключ восстановления будет показан после настройки.",
                          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                        ),
                      ],
                      if (!needsSetup) ...[
                        const SizedBox(height: 6),
                        Text(
                          "Element: Настройки → Безопасность и приватность → "
                          "Шифрование → Ключ восстановления",
                          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: recoveryKeyController,
                          decoration: InputDecoration(
                            hintText: 'EsTp ESYQ baBY APgP ...',
                            hintStyle: TextStyle(fontSize: 12, color: Colors.grey[400]),
                            border: const OutlineInputBorder(),
                            errorText: dialogError,
                            errorStyle: const TextStyle(fontSize: 11),
                          ),
                          style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                          maxLines: 4,
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text("Пропустить"),
                  ),
                  if (needsSetup)
                    ElevatedButton(
                      onPressed: () async {
                        setDialogState(() { dialogError = null; });
                        Navigator.pop(dialogContext); // закрываем этот диалог
                        // Вызываем setupCryptoIdentity еще раз — теперь accountData синхронизирована
                        try {
                          final ok = await widget.matrixService.keys.setupCryptoIdentity();
                          if (ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Шифрование настроено! Сохраните ключ восстановления.'),
                                backgroundColor: Colors.green,
                              ),
                            );
                          } else if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Не удалось настроить шифрование. Попробуйте позже.'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Ошибка: $e'),
                                backgroundColor: Colors.red,
                              ),
                            );
                          }
                        }
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo),
                      child: const Text("Настроить", style: TextStyle(color: Colors.white)),
                    ),
                  if (!needsSetup)
                    ElevatedButton(
                      onPressed: () async {
                        final key = recoveryKeyController.text.trim();
                        if (key.isEmpty) {
                          setDialogState(() { dialogError = 'Введите ключ'; });
                          return;
                        }
                        setDialogState(() { dialogError = null; });
                        try {
                          final ok = await widget.matrixService.restoreCryptoIdentity(key);
                          if (ok) {
                            Navigator.pop(dialogContext);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Ключ восстановлен! Шифрование работает.'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            }
                          } else {
                            setDialogState(() { dialogError = 'Неверный ключ восстановления'; });
                          }
                        } catch (e) {
                          setDialogState(() { dialogError = 'Ошибка: $e'; });
                        }
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                      child: const Text("Восстановить", style: TextStyle(color: Colors.white)),
                    ),
                ],
              );
            },
          );
        },
      );
    } catch (e) {
      debugPrint('[LOGIN] Crypto identity check error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Вход')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 60, color: Colors.indigo),
            const SizedBox(height: 20),
            const Text(
              "Ваш сервер: xemooll.ru",
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 30),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: 'Логин',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: 'Пароль',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock),
              ),
              obscureText: true,
              onSubmitted: (_) => _loginOrRegister(),
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ),
            if (_isLoading)
              const CircularProgressIndicator()
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loginOrRegister,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('ВОЙТИ / РЕГИСТРАЦИЯ'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
