import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/account_request.dart';
import 'package:se_mobile/screens/change_password_screen.dart';
import 'package:se_mobile/utils/desktop.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/logout_helper.dart';
import 'package:se_mobile/utils/own_password.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';

import 'support/fake_server.dart';

/// Первый вход с телефона и из браузера: код с бумажки и сразу код из
/// четырёх цифр.
///
/// Свой пароль на телефоне придумывали и тут же забывали: дальше вход по
/// коду или пальцем. Теперь телефон и браузер гасят выданный код на сервере,
/// а пароль задают позже в «Настройках» — те, кому нужен вход с компьютера.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    OwnPassword.has.value = true;
  });
  tearDown(() {
    debugDesktopOverride = null;
    debugIosBrowserTabOverride = null;
  });

  test('пароль при первом входе нужен только на компьютере', () {
    debugDesktopOverride = false;
    expect(passwordNeededToStart, isFalse);
    debugDesktopOverride = true;
    expect(passwordNeededToStart, isTrue);
  });

  test('вне браузера вкладки на iPhone не бывает', () {
    debugDesktopOverride = false;
    expect(iosBrowserTab, isFalse);
    expect(spendIssuedPasswordHere, isTrue);
  });

  /// Сервер, который гасит выданный код, как настоящий.
  FakeServer codeServer({int status = 200, bool hasPassword = false}) =>
      FakeServer.routed((method, url, body) =>
          url.path == '/api/account/code-used'
              ? (
                  status,
                  status == 200
                      ? jsonEncode(
                          {'message': 'Success', 'has_password': hasPassword})
                      : jsonEncode(
                          {'message': 'Failure', 'error': 'password_required'})
                )
              : (404, '{}'));

  group('вошли с выданным паролем', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({'token': 't'}));

    test('на телефоне и в браузере — гасим и пускаем без своего пароля',
        () async {
      debugDesktopOverride = false;
      debugIosBrowserTabOverride = false;
      final server = codeServer();
      final ok = await HttpOverrides.runWithHttpOverrides(
          settleIssuedPassword, server);
      expect(ok, isTrue);
      expect(server.requests, hasLength(1));
      expect(OwnPassword.has.value, isFalse);
    });

    test('во вкладке на iPhone — пускаем, а код не гасим: им войдут со значка',
        () async {
      debugDesktopOverride = false;
      debugIosBrowserTabOverride = true;
      expect(spendIssuedPasswordHere, isFalse);
      final server = codeServer();
      final ok = await HttpOverrides.runWithHttpOverrides(
          settleIssuedPassword, server);
      expect(ok, isTrue);
      expect(server.requests, isEmpty);
      expect(OwnPassword.has.value, isTrue);
    });

    test('на компьютере — придумать пароль, сервер не трогаем', () async {
      debugDesktopOverride = true;
      final server = codeServer();
      final ok = await HttpOverrides.runWithHttpOverrides(
          settleIssuedPassword, server);
      expect(ok, isFalse);
      expect(server.requests, isEmpty);
    });

    test('сервер не согласился (admin) — придумать пароль, как прежде',
        () async {
      debugDesktopOverride = false;
      debugIosBrowserTabOverride = false;
      final server = codeServer(status: 403);
      final ok = await HttpOverrides.runWithHttpOverrides(
          settleIssuedPassword, server);
      expect(ok, isFalse);
      expect(OwnPassword.has.value, isTrue);
    });
  });

  test('сервер погасил код — своего пароля нет', () async {
    FlutterSecureStorage.setMockInitialValues({'token': 't'});
    final server = FakeServer.routed((method, url, body) =>
        url.path == '/api/account/code-used'
            ? (200, jsonEncode({'message': 'Success', 'has_password': false}))
            : (404, '{}'));
    final ok = await HttpOverrides.runWithHttpOverrides(
        spendOneTimeCode, server);
    expect(ok, isTrue);
    expect(OwnPassword.has.value, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('has_password'), isFalse);
  });

  test('старый сервер адреса не знает — просим пароль, как прежде', () async {
    FlutterSecureStorage.setMockInitialValues({'token': 't'});
    final server = FakeServer.routed(
        (method, url, body) => (404, jsonEncode({'message': 'Failure'})));
    final ok = await HttpOverrides.runWithHttpOverrides(
        spendOneTimeCode, server);
    expect(ok, isFalse);
    expect(OwnPassword.has.value, isTrue);
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

  group('пароль для входа с компьютера', () {
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
      expect(find.text('Пароль для входа с компьютера'), findsOneWidget);
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
