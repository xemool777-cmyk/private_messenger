# 📱 Private Messenger — E2EE Matrix-чат с голосом и видео

[![Flutter](https://img.shields.io/badge/Flutter-3.3+-02569B?style=flat-square&logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.3+-0175C2?style=flat-square&logo=dart)](https://dart.dev)
[![Matrix](https://img.shields.io/badge/Matrix-SDK%207.x-000?style=flat-square&logo=matrix)](https://matrix.org)
[![E2EE](https://img.shields.io/badge/E2EE-Vodozemac-brightgreen?style=flat-square)](https://github.com/matrix-org/vodozemac)
[![WebRTC](https://img.shields.io/badge/WebRTC-audio%2Fvideo-333?style=flat-square&logo=webrtc)](https://webrtc.org)
[![License](https://img.shields.io/badge/license-MIT-lightgrey?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Web%20%7C%20Desktop-6DB33F?style=flat-square)](https://flutter.dev)

> **Приватный мессенджер с E2EE-шифрованием, офлайн-меш-поддержкой и аудио/видео-звонками.**
>
> Построен на Matrix SDK 7.x — децентрализованный протокол, полное сквозное шифрование, никакого доступа к переписке третьими сторонами.

## ✨ Возможности

| Функция | Статус | Описание |
|---------|:------:|----------|
| **E2EE-шифрование** | ✅ | Vodozemac Flutter — сквозное шифрование всех сообщений |
| **Текстовый чат** | ✅ | Отправка и получение сообщений в реальном времени |
| **Аудио-сообщения** | ✅ | Запись через микрофон и воспроизведение |
| **Видео-сообщения** | ✅ | Съёмка с камеры и встроенный плеер |
| **Изображения и файлы** | ✅ | File picker + галерея в чате |
| **WebRTC звонки** | ✅ | Аудио и видео вызовы через Matrix |
| **Push-уведомления** | ✅ | Нативные + Web Push API |
| **Авторизация** | ✅ | Логин/пароль через Matrix HSD |
| **Офлайн-синхронизация** | ✅ | Sync service через LRU-кэш изображений |
| **Кроссплатформа** | ✅ | Android, iOS, Web, Linux, macOS, Windows |

## 🏗 Архитектура

```
lib/
├── main.dart                 # Точка входа
├── config/
│   └── app_config.dart       # Конфигурация приложения
├── screens/
│   ├── login_screen.dart      # Экран входа
│   ├── chats_screen.dart      # Список чатов
│   ├── chat_room_screen.dart  # Комната чата
│   ├── profile_screen.dart    # Профиль пользователя
│   └── call_screen.dart       # Аудио/видео звонок
├── services/
│   ├── auth_service.dart      # Аутентификация
│   ├── matrix_service.dart    # Matrix SDK — ядро протокола
│   ├── sync_service.dart      # Офлайн-синхронизация
│   ├── media_service.dart     # Аудио/видео/файлы
│   ├── call_service.dart      # WebRTC звонки
│   ├── keys_service.dart      # E2EE-ключи (Vodozemac)
│   ├── notification_service.dart       # Push (нативные)
│   └── notification_service_web.dart   # Push (Web)
├── widgets/
│   ├── message_bubble.dart     # Пузырёк сообщения
│   ├── timeline_list.dart      # Лента сообщений
│   ├── input_bar.dart          # Поле ввода
│   ├── image_gallery.dart      # Галерея изображений
│   └── fullscreen_image.dart   # Просмотр на весь экран
└── helpers/
    ├── camera_video.dart        # Видео-запись
    ├── camera_video_web.dart    # Видео-запись (Web)
    └── camera_video_stub.dart   # Заглушка
```

## 🔐 Безопасность

- **Сквозное шифрование (E2EE)** — реализовано через [Vodozemac](https://github.com/matrix-org/vodozemac) (Rust → Flutter FFI)
- **Secure Storage** — ключи шифрования хранятся в `flutter_secure_storage` (AES-256 на iOS/Android)
- **Matrix Protocol** — децентрализованный, сервер не имеет доступа к содержимому
- **Offline mesh** — сообщения синхронизируются при восстановлении соединения

## 🚀 Быстрый старт

```bash
# 1. Клонировать
git clone https://github.com/xemool777-cmyk/private_messenger.git
cd private_messenger

# 2. Установка зависимостей
flutter pub get

# 3. Сборка
flutter build apk          # Android
flutter build ios          # iOS
flutter build web          # Web
flutter build linux        # Linux

# 4. Запуск в dev-режиме
flutter run -d chrome      # Web
flutter run                # Подключенное устройство
```

### Конфигурация

Создайте `lib/config/secrets.dart` (не в репозитории):

```dart
class Secrets {
  static const homeserver = 'https://matrix.example.com';
}
```

## 📦 Технологии

| Компонент | Технология |
|-----------|------------|
| **Фреймворк** | Flutter 3.3+ / Dart 3.3+ |
| **Протокол** | Matrix SDK 7.1.2 |
| **E2EE** | flutter_vodozemac 0.5.0 (Rust → Dart FFI) |
| **Аудио** | record 5.1, audioplayers 6.1 |
| **Видео** | image_picker 1.1, video_player 2.9 |
| **Звонки** | flutter_webrtc 1.4 |
| **Хранилище** | flutter_secure_storage 9.2 |
| **Push** | notification_service + Web Push API |
| **Платформы** | Android, iOS, Web, Linux, macOS, Windows |

## 📄 Лицензия

```
MIT License
Copyright © 2026 xemool777-cmyk
```

---

*Built with Flutter — one codebase, six platforms, zero compromises.*