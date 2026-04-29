import 'package:flutter/material.dart';
import 'services/matrix_service.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final matrixService = MatrixService();
  await matrixService.init();

  runApp(MyApp(matrixService: matrixService));
}

class MyApp extends StatelessWidget {
  final MatrixService matrixService;
  const MyApp({super.key, required this.matrixService});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Private Messenger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.indigo,
          foregroundColor: Colors.white,
        ),
      ),
      home: LoginPage(matrixService: matrixService),
    );
  }
}
