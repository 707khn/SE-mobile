import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/about_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// «Сервер» и «Последние ошибки» — только администратору системы.
void main() {
  Future<void> open(WidgetTester tester, String job) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'job': job});
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const AboutScreen(),
      ));
      for (var i = 0; i < 5; i++) {
        await tester
            .runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }, FakeServer(404, ''));
  }

  testWidgets('сотрудник видит только версию', (tester) async {
    await open(tester, 'Слесарь');
    expect(find.text('Версия'), findsOneWidget);
    expect(find.text('Сервер'), findsNothing);
    expect(find.text('Последние ошибки'), findsNothing);
  });

  testWidgets('администратор видит сервер и ошибки', (tester) async {
    await open(tester, 'Администратор системы');
    expect(find.text('Сервер'), findsOneWidget);
    expect(find.text('Последние ошибки'), findsOneWidget);
  });
}
