import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Экран не поворачивается. Приложение свёрстано под телефон в руке: лёжа
/// набок, например, клавиатура кода не помещалась по высоте, и ноль со
/// «стереть» уходили за край. Запрет держится в трёх местах — проверка
/// следит, чтобы ни одно не потерялось.
void main() {
  test('Android: только портрет', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:screenOrientation="portrait"'));
  });

  test('приложение само просит портрет', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main,
        contains('setPreferredOrientations([DeviceOrientation.portraitUp])'));
  });

  test('iPhone: только портрет', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final start = plist.indexOf('<key>UISupportedInterfaceOrientations</key>');
    final end = plist.indexOf('</array>', start);
    expect(plist.substring(start, end), isNot(contains('Landscape')));
  });
}
