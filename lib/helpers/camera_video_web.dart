import 'dart:async';
import 'dart:html' as html;
import 'dart:typed_data';

/// Открывает камеру напрямую (без файлового диалога) через
/// `<input type="file" accept="video/*" capture="environment">`.
///
/// Возвращает `(bytes, name)` или `null` при отмене пользователем.
Future<({Uint8List bytes, String name})?> pickVideoFromCamera() async {
  final completer =
      Completer<({Uint8List bytes, String name})?>();

  final input = html.FileUploadInputElement()
    ..accept = 'video/*'
    // capture="environment" — задняя камера; "user" — фронтальная
    ..setAttribute('capture', 'environment')
    ..style.display = 'none';

  html.document.body!.append(input);

  input.onChange.listen((event) {
    final files = input.files;
    if (files == null || files.isEmpty) {
      completer.complete(null);
      input.remove();
      return;
    }

    final file = files.first;
    final reader = html.FileReader();
    reader.onLoad.listen((_) {
      final bytes = reader.result as List<int>;
      completer.complete((
        bytes: Uint8List.fromList(bytes),
        name: file.name,
      ));
      input.remove();
    });
    reader.onError.listen((_) {
      completer.complete(null);
      input.remove();
    });
    reader.readAsArrayBuffer(file);
  });

  // Пользователь мог закрыть диалог камеры — детектим по blur+focus с задержкой
  var _wasBlurred = false;

  html.window.onBlur.listen((_) {
    _wasBlurred = true;
  });

  html.window.onFocus.listen((_) {
    if (!_wasBlurred || completer.isCompleted) return;
    _wasBlurred = false;
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!completer.isCompleted) {
        completer.complete(null);
        input.remove();
      }
    });
  });

  input.click();
  return completer.future;
}
