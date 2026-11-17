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
import 'package:se_mobile/utils/logout_helper.dart';
import 'package:se_mobile/utils/own_password.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';

import 'support/fake_server.dart';

/// Первый вход по коду из ОИТиС: везде — свой пароль от восьми символов.
///
/// Было: телефон и браузер гасили выданный код, и своего пароля не
/// оставалось — выйдя или сменив телефон, человек возвращался только по
/// новому коду, а значок на iPhone снова просил пароль. Теперь после кода
/// везде «Придумайте пароль», а у кого пароля нет — задают в «Настройках».
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OwnPassword.has.value = true;
  });

  group('после входа по коду', () {
    Future<FakeServer> open(WidgetTester tester, String error) async {
      await tester.runAsync(Lang.initDates);
      FlutterSecureStorage.setMockInitialValues({'token': 't'});
      final server = FakeServer.routed((method, url, body) =>
          url.path == '/change-password'
              ? (400, jsonEncode({'message': 'Failure', 'error': error}))
              : (404, '{}'));
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const ChangePasswordScreen(
            fullName: 'Цехов Тест', job: 'Слесарь', currentPassword: '48213'),
      ));
      return server;
    }

    Future<void> submit(
            WidgetTester tester, FakeServer server, String password) =>
        HttpOverrides.runWithHttpOverrides(() async {
          final fields = find.byType(TextField);
          await tester.enterText(fields.at(0), password);
          await tester.enterText(fields.at(1), password);
          await tester.tap(find.byType(ElevatedButton));
          for (var i = 0; i < 5; i++) {
            await tester.runAsync(
                () => Future.delayed(const Duration(milliseconds: 40)));
            await tester.pump();
          }
        }, server);

    testWidgets('просят придумать пароль, код с входа уже подставлен',
        (tester) async {
      await open(tester, 'too_short');
      expect(find.text('Придумайте пароль'), findsOneWidget);
      expect(find.text('Текущий пароль'), findsNothing);
      expect(find.textContaining('Не короче 8 символов'), findsOneWidget);
    });

    testWidgets('короткий пароль — сервер не принял, объясняем',
        (tester) async {
      final server = await open(tester, 'too_short');
      await submit(tester, server, 'Цех-202');
      final sent = jsonDecode(server.requests.single) as Map<String, dynamic>;
      expect(sent['old_password'], '48213');
      expect(sent['new_password'], 'Цех-202');
      expect(find.text('Нужно не меньше 8 символов'), findsOneWidget);
    });
  });

  testWidgets('без пароля выход предупреждает, что вернуться — по новому коду',
      (tester) async {
    OwnPassword.has.value = false;
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => confirmAndLogout(context),
          child: const Text('выйти'),
        ),
      ),
    ));
    await tester.tap(find.text('выйти'));
    await tester.pumpAndSettle();
    expect(find.textContaining('только по новому коду из ОИТиС'),
        findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
  });

  group('пароля нет — задать в «Настройках»', () {
    Future<FakeServer> open(WidgetTester tester) async {
      await tester.runAsync(Lang.initDates);
      FlutterSecureStorage.setMockInitialValues({'token': 't', 'pin': '2580'});
      final server = FakeServer.routed((method, url, body) =>
          url.path == '/change-password'
              ? (200, jsonEncode({'message': 'Success', 'token': 't2'}))
              : (404, '{}'));
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const ChangePasswordScreen(
            fullName: 'Цехов Тест',
            job: 'Слесарь',
            currentPassword: '',
            mandatory: false,
            hasPassword: false),
      ));
      return server;
    }

    Future<void> submit(WidgetTester tester, FakeServer server, String pin) =>
        HttpOverrides.runWithHttpOverrides(() async {
          final fields = find.byType(TextField);
          await tester.enterText(fields.at(0), pin);
          await tester.enterText(fields.at(1), 'Цех-2026-ok');
          await tester.enterText(fields.at(2), 'Цех-2026-ok');
          await tester.tap(find.byType(ElevatedButton));
          for (var i = 0; i < 5; i++) {
            await tester.runAsync(
                () => Future.delayed(const Duration(milliseconds: 40)));
            await tester.pump();
          }
        }, server);

    testWidgets('вместо старого пароля спрашивают код', (tester) async {
      await open(tester);
      expect(find.text('Задать пароль'), findsOneWidget);
      expect(find.text('Код для входа в приложение'), findsOneWidget);
      expect(find.text('Текущий пароль'), findsNothing);
    });

    testWidgets('неверный код — до сервера не доходит, попытка в счёт',
        (tester) async {
      final server = await open(tester);
      await submit(tester, server, '1111');
      expect(server.requests, isEmpty);
      expect(find.text('Неверный код. Осталось попыток: 4'), findsOneWidget);
      final fails =
          await tester.runAsync(SecureStorageHelper.instance.getPinFails);
      expect(fails, 1);
    });

    testWidgets('верный код — пароль задан без старого', (tester) async {
      final server = await open(tester);
      await submit(tester, server, '2580');
      expect(server.requests, hasLength(1));
      final sent = jsonDecode(server.requests.single) as Map<String, dynamic>;
      expect(sent['old_password'], '');
      expect(sent['new_password'], 'Цех-2026-ok');
      expect(OwnPassword.has.value, isTrue);
    });
  });
}
