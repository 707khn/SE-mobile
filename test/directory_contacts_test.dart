import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/directory_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Два номера из одной ячейки справочника — две кнопки.
///
/// Раньше оба стояли на одной, и по нажатию набиралось одно число в двадцать
/// две цифры. Номера здесь выдуманные.
void main() {
  Future<void> open(WidgetTester tester) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final fake = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'entries': [
              {
                'department': 'Тестовый отдел',
                'name': 'Тестов Тест',
                'position': 'Инженер',
                'extension': '215',
                'email': 'one@example.kz, two@example.kz',
                'mobile': '8 700 000 11 22, 8 700 000 33 44',
              },
            ],
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const DirectoryScreen(),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }, fake);
  }

  testWidgets('каждый номер и адрес — своей кнопкой', (tester) async {
    await open(tester);
    expect(find.text('8 700 000 11 22'), findsOneWidget);
    expect(find.text('8 700 000 33 44'), findsOneWidget);
    expect(find.text('one@example.kz'), findsOneWidget);
    expect(find.text('two@example.kz'), findsOneWidget);
    expect(find.text('215'), findsOneWidget);
  });

  testWidgets('не открылось — сказано, а не тишина', (tester) async {
    // Набора номера в проверках нет — как нет почтовой программы на части
    // телефонов.
    await open(tester);
    await tester.tap(find.text('two@example.kz'));
    await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    expect(find.text('url_error'.tr), findsOneWidget);
  });
}
