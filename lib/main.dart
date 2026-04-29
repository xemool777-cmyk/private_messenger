import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  
  final client = Client(
    'PrivateMessenger',
  );

  runApp(MyApp(client: client));
}

class MyApp extends StatelessWidget {
  final Client client;
  const MyApp({super.key, required this.client});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Private Messenger',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
        ),
      ),
      home: LoginPage(client: client),
    );
  }
}

// --- ЭКРАН ВХОДА ---
class LoginPage extends StatefulWidget {
  final Client client;
  const LoginPage({super.key, required this.client});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  Future<void> _loginOrRegister() async {
    setState(() { _isLoading = true; _error = null; });

    try {
      if (widget.client.isLogged()) {
         Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatsScreen(client: widget.client)));
         return;
      }

      await widget.client.checkHomeserver(Uri.parse('https://xemooll.ru'));

      try {
        await widget.client.login(
          LoginType.mLoginPassword,
          password: _passwordController.text,
          identifier: AuthenticationUserIdentifier(user: _usernameController.text),
        );
      } on MatrixException catch (e) {
        if (e.errcode == 'M_FORBIDDEN' || e.errcode == 'M_USER_IN_USE') {
           await widget.client.register(
             username: _usernameController.text,
             password: _passwordController.text,
             auth: AuthenticationData.fromJson({'type': 'm.login.dummy'}),
           );
        } else { throw e; }
      }
      
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ChatsScreen(client: widget.client)));

    } catch (e) {
      setState(() { _error = "Ошибка: $e"; });
    } finally {
      setState(() { _isLoading = false; });
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
             const Text("Ваш сервер: xemooll.ru", style: TextStyle(color: Colors.grey)),
             const SizedBox(height: 30),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: 'Логин', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Пароль', border: OutlineInputBorder()),
              obscureText: true,
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
            const SizedBox(height: 10),
            if (_isLoading)
              const CircularProgressIndicator()
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loginOrRegister,
                  child: const Text('ВОЙТИ / РЕГИСТРАЦИЯ'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// --- ЭКРАН СПИСКА ЧАТОВ (КРАСИВЫЙ) ---
class ChatsScreen extends StatefulWidget {
  final Client client;
  const ChatsScreen({super.key, required this.client});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  List<Room> _rooms = [];

  @override
  void initState() {
    super.initState();
    _loadRooms();
    widget.client.onSync.stream.listen((event) => _loadRooms());
  }

  void _loadRooms() {
    if (mounted) {
      setState(() { _rooms = widget.client.rooms; });
    }
  }

  Future<void> _createChat() async {
    final TextEditingController userController = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Начать чат"),
          content: TextField(
            controller: userController,
            decoration: const InputDecoration(
              labelText: "Имя пользователя (без @)",
              hintText: "Например: user2"
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text("Отмена")),
            ElevatedButton(
              onPressed: () async {
                final username = userController.text.trim();
                if (username.isEmpty) return;
                Navigator.pop(context);
                try {
                  final userId = "@$username:xemooll.ru";
                  await widget.client.createRoom(
                    isDirect: true,
                    invite: [userId],
                    preset: CreateRoomPreset.privateChat,
                    name: "Чат с $username",
                  );
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Чат создан!")));
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Ошибка: $e")));
                }
              },
              child: const Text("Создать"),
            ),
          ],
        );
      },
    );
  }

  // ИСПРАВЛЕНО: Принимаем DateTime
  String _formatTime(DateTime date) {
    return "${date.hour}:${date.minute.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Мессенджер", style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.indigo,
        actions: [
          IconButton(
            icon: const Icon(Icons.exit_to_app),
            onPressed: () async {
              await widget.client.logout();
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => LoginPage(client: widget.client)));
            },
          )
        ],
      ),
      body: _rooms.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 60, color: Colors.grey[400]),
                  const SizedBox(height: 10),
                  const Text("Нет чатов", style: TextStyle(color: Colors.grey, fontSize: 18)),
                ],
              )
            )
          : ListView.separated(
              itemCount: _rooms.length,
              separatorBuilder: (ctx, i) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final room = _rooms[index];
                final lastEvent = room.lastEvent;
                
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: CircleAvatar(
                    backgroundColor: Colors.indigo[300],
                    child: Text(
                      room.displayname[0].toUpperCase(), 
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)
                    ),
                  ),
                  title: Text(room.displayname, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  subtitle: Text(
                    lastEvent?.body ?? "Нет сообщений", 
                    maxLines: 1, 
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                  trailing: lastEvent != null 
                    ? Text(_formatTime(lastEvent.originServerTs), style: TextStyle(color: Colors.grey[400], fontSize: 12)) 
                    : null,
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(
                      builder: (_) => ChatRoomScreen(client: widget.client, room: room)
                    ));
                  },
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createChat,
        backgroundColor: Colors.indigo,
        child: const Icon(Icons.add_comment_rounded, color: Colors.white),
      ),
    );
  }
}

// --- ЭКРАН ПЕРЕПИСКИ (КРАСИВЫЙ) ---
class ChatRoomScreen extends StatefulWidget {
  final Client client;
  final Room room;
  const ChatRoomScreen({super.key, required this.client, required this.room});

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final _controller = TextEditingController();
  Timeline? _timeline; 
  bool _isLoading = true;
  StreamSubscription? _updateSub; 

  @override
  void initState() {
    super.initState();
    _loadTimeline();
    _updateSub = widget.room.onUpdate.stream.listen((event) => _loadTimeline());
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    super.dispose();
  }

  void _loadTimeline() async {
    if (!mounted) return;
    try {
      if (widget.room.getState(EventTypes.RoomCreate) == null) {
         await widget.room.postLoad();
      }
      final timeline = await widget.room.getTimeline();
      if (mounted) {
        setState(() {
          _timeline = timeline;
          _isLoading = false;
        });
      }
    } catch (e) {
      print("Error: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _sendMessage() async {
    if (_controller.text.isEmpty) return;
    final text = _controller.text;
    
    try {
      _controller.clear();
      await widget.room.sendTextEvent(text);
      _loadTimeline();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Ошибка: $e")));
    }
  }

  // ИСПРАВЛЕНО: Принимаем DateTime
  String _formatMsgTime(DateTime date) {
    return "${date.hour}:${date.minute.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.room.displayname),
        backgroundColor: Colors.indigo,
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading 
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  padding: const EdgeInsets.all(10),
                  reverse: true,
                  itemCount: _timeline?.events.length ?? 0,
                  itemBuilder: (context, index) {
                    final event = _timeline!.events[index];
                    final isMe = event.senderId == widget.client.userID;
                    
                    if (event.type != "m.room.message") return Container();

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (!isMe)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: CircleAvatar(
                                radius: 14,
                                backgroundColor: Colors.grey[300],
                                child: Text(event.senderId?.localpart?[0].toUpperCase() ?? "?", style: const TextStyle(fontSize: 12)),
                              ),
                            ),
                          
                          Flexible(
                            child: Container(
                              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: isMe ? Colors.indigo[400] : Colors.grey[200],
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(16),
                                  topRight: const Radius.circular(16),
                                  bottomLeft: isMe ? const Radius.circular(16) : const Radius.circular(0),
                                  bottomRight: isMe ? const Radius.circular(0) : const Radius.circular(16),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    event.body ?? "",
                                    style: TextStyle(
                                      color: isMe ? Colors.white : Colors.black87,
                                      fontSize: 16,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _formatMsgTime(event.originServerTs),
                                    style: TextStyle(
                                      color: isMe ? Colors.white70 : Colors.grey[500],
                                      fontSize: 10,
                                    ),
                                    textAlign: TextAlign.right,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (isMe) const SizedBox(width: 8),
                        ],
                      ),
                    );
                  },
                ),
          ),
          
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.grey[300]!, blurRadius: 4, offset: const Offset(0, -1))],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _controller,
                      decoration: const InputDecoration(
                        hintText: "Сообщение...",
                        border: InputBorder.none,
                      ),
                      minLines: 1,
                      maxLines: 5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: Colors.indigo,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white, size: 20),
                    onPressed: _sendMessage,
                  ),
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}