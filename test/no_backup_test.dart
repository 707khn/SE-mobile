import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Данные приложения не уходят ни в облачную копию, ни на новый телефон.
///
/// В них сохранённые листки и проходы. А пропуск и код лежат под ключом из
/// Keystore, который в копию не попадает: восстановленное на новом телефоне
/// хранилище не расшифровывается, и приложение падает, а не просит войти.
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  test('до Android 12: копия выключена', () {
    expect(manifest, contains('android:allowBackup="false"'));
    expect(manifest, contains('android:fullBackupContent="false"'));
  });

  test('Android 12 и новее: ни облако, ни перенос на новый телефон', () {
    expect(manifest,
        contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
    final rules = File('android/app/src/main/res/xml/data_extraction_rules.xml')
        .readAsStringSync();
    for (final section in ['cloud-backup', 'device-transfer']) {
      final start = rules.indexOf('<$section>');
      final end = rules.indexOf('</$section>');
      expect(start, greaterThan(-1), reason: section);
      final body = rules.substring(start, end);
      for (final domain in ['root', 'file', 'database', 'sharedpref']) {
        expect(body, contains('domain="$domain"'), reason: '$section/$domain');
      }
    }
  });
}
