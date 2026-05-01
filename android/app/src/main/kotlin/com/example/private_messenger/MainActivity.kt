package com.example.private_messenger

import io.flutter.embedding.android.FlutterActivity

class MainActivity: FlutterActivity() {
    init {
        // Загружаем libolm.so для E2EE шифрования
        System.loadLibrary("olm")
    }
}
