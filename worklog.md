---
Task ID: 1
Agent: Main Agent
Task: Fix critical issues in Private Messenger - sync not working, no persistence, refactor

Work Log:
- Cloned repo from https://github.com/xemool777-cmyk/private_messenger
- Analyzed project structure: single-file main.dart (463 lines), Flutter+Matrix SDK
- Identified root cause #1: Client created without databaseBuilder = in-memory only, no persistence
- Identified root cause #2: Missing client.init() call - sync loop never starts properly
- Researched Matrix Dart SDK v0.22.7 API: correct class is HiveCollectionsDatabase, startSync() doesn't exist
- Refactored code into modular structure:
  - lib/main.dart (thin entry point)
  - lib/services/matrix_service.dart (Client lifecycle, login, persistence)
  - lib/screens/login_screen.dart (login UI with session resume)
  - lib/screens/chats_screen.dart (room list with pull-to-refresh)
  - lib/screens/chat_room_screen.dart (messages with sync indicator)
- Added HiveCollectionsDatabase for persistence
- Added client.init() call to start sync loop
- Improved error handling, UX, date headers, message status indicators
- Removed unused import (flutter/material from matrix_service)
- Kept hive_flutter commented out in pubspec (matrix uses hive as transitive dep)

Stage Summary:
- Critical sync fix: client.init() now called after Client creation with databaseBuilder
- Persistence: HiveCollectionsDatabase stores session and messages
- Code structure: single file → 5 modular files
- API verified: HiveCollectionsDatabase(name, path) + await db.open()
- Ready for user to test on their Flutter dev environment
