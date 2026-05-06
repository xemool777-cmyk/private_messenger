/// Stub для нативных платформ (Android/iOS/Desktop)
/// Runtime-конфигурация через config.js недоступна — используем --dart-define

/// На нативных платформах всегда null — используется --dart-define
String? getHomeserverUrlFromRuntime() => null;

/// На нативных платформах всегда null — используется --dart-define
String? getServerNameFromRuntime() => null;
