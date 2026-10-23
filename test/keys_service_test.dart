import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/services/keys_service.dart';

void main() {
  group('KeysService: ключ восстановления', () {
    test('savedRecoveryKey по умолчанию равен null', () {
      expect(KeysService.savedRecoveryKey, isNull);
    });

    test('setRecoveryKey сохраняет ключ, savedRecoveryKey его возвращает', () {
      const key = 'EsTb recovery key value';

      KeysService.setRecoveryKey(key);

      expect(KeysService.savedRecoveryKey, key);
    });

    test('setRecoveryKey перезаписывает предыдущее значение', () {
      KeysService.setRecoveryKey('first');
      KeysService.setRecoveryKey('second');

      expect(KeysService.savedRecoveryKey, 'second');
    });
  });

  group('KeysService: пароль', () {
    test('hasPassword по умолчанию равен false', () {
      expect(KeysService.hasPassword, isFalse);
    });

    test('setPassword устанавливает пароль, hasPassword становится true', () {
      KeysService.setPassword('secret');

      expect(KeysService.hasPassword, isTrue);
    });

    test('повторный setPassword сохраняет пароль доступным', () {
      KeysService.setPassword('one');
      KeysService.setPassword('two');

      expect(KeysService.hasPassword, isTrue);
    });
  });

  group('KeysService: onUiaFailed', () {
    tearDown(() {
      KeysService.onUiaFailed.value = null;
    });

    test('по умолчанию значение равно null', () {
      expect(KeysService.onUiaFailed.value, isNull);
    });

    test('устанавливает сообщение об ошибке', () {
      KeysService.onUiaFailed.value = 'Требуется пароль';

      expect(KeysService.onUiaFailed.value, 'Требуется пароль');
    });

    test('уведомляет подписчиков при изменении значения', () {
      final values = <String?>[];
      void listener() => values.add(KeysService.onUiaFailed.value);
      KeysService.onUiaFailed.addListener(listener);
      addTearDown(() => KeysService.onUiaFailed.removeListener(listener));

      KeysService.onUiaFailed.value = 'Ошибка UIA';
      KeysService.onUiaFailed.value = null;

      expect(values, ['Ошибка UIA', null]);
    });
  });
}
