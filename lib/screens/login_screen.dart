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
      }
    } catch (e) {
      String errorMsg = 'Ошибка подключения';
      if (e.toString().contains('M_FORBIDDEN')) {
        errorMsg = 'Неверный логин или пароль';
      } else if (e.toString().contains('Connection')) {
        errorMsg = 'Нет связи с сервером';
      } else {
        errorMsg = 'Ошибка: $e';
      }
      setState(() { _error = errorMsg; });
    } finally {
      if (mounted) setState(() { _isLoading = false; });
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
            Text(
              "Ваш сервер: ${MatrixService.serverName}",
              style: const TextStyle(color: Colors.grey),
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
