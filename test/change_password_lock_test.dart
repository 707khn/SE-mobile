import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/change_password_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Смена пароля закрыта после пяти неверных старых паролей, как и вход.
/// Человек должен узнать, сколько ждать, — а не прочитать «сервер ответил
/// ошибкой» и нажимать снова, продлевая замок.
void main() {
  testWidgets('замок назван замком и со сроком', (tester) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'token': 't'});
    final server = FakeServer(
        429, jsonEncode({'message': 'Failure', 'error': 'locked', 'retry_after': 240}),
        contentType: 'application/json; charset=utf-8');
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const ChangePasswordScreen(
            fullName: 'Замков Тест', job: 'Слесарь', currentPassword: '',
            mandatory: false),
      ));
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'старая-фраза');
      await tester.enterText(fields.at(1), 'новая-длинная-фраза-2026');
      await tester.enterText(fields.at(2), 'новая-длинная-фраза-2026');
      await tester.tap(find.byType(ElevatedButton));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }, server);
    expect(find.text('login_locked_wait'.trParams({'minutes': '4'})),
        findsOneWidget);
  });
}
