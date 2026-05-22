import 'package:flutter_test/flutter_test.dart';
import 'package:private_messenger/services/matrix_service.dart';

void main() {
  test('buildUserId формирует корректный Matrix ID', () {
    expect(MatrixService.buildUserId('alice'), '@alice:xemooll.ru');
    expect(MatrixService.buildUserId('bob123'), '@bob123:xemooll.ru');
  });

  test('homeserverUrl и serverName заданы корректно', () {
    expect(MatrixService.homeserverUrl, 'https://xemooll.ru');
    expect(MatrixService.serverName, 'xemooll.ru');
  });
}
