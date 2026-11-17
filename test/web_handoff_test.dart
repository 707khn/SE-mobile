import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/web_handoff_request.dart';
import 'package:se_mobile/utils/desktop.dart';
import 'package:se_mobile/utils/own_password.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';

import 'support/fake_server.dart';

/// Вход из Safari — значку на экране «Домой» (сервер — web_handoff.py).
///
/// На iPhone значок хранит своё отдельно от Safari и снова спрашивал
/// пароль. Теперь вошедшая вкладка оставляет куку, а значок при первом
/// запуске забирает по ней свой пропуск.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    OwnPassword.has.value = true;
  });
  tearDown(() {
    debugDesktopOverride = null;
    debugIosBrowserTabOverride = null;
    debugIosHomeScreenIconOverride = null;
  });

  /// Сервер передачи входа: что ответить на claim, и учёт адресов.
  (FakeServer, List<String>) server(Map<String, dynamic> claim) {
    final paths = <String>[];
    final fake = FakeServer.routed((method, url, body) {
      paths.add(url.path);
      switch (url.path) {
        case '/api/web-handoff/claim':
          return (200, jsonEncode(claim));
        case '/api/web-handoff':
          return (200, jsonEncode({'message': 'Success'}));
        case '/api/account/code-used':
          return (200, jsonEncode({'message': 'Success', 'has_password': false}));
      }
      return (404, '{}');
    });
    return (fake, paths);
  }

  const approved = {
    'message': 'Success',
    'status': 'approved',
    'token': 'icon-token',
    'login': '1234',
    'full_name': 'Иванов Иван',
    'job': 'Слесарь',
    'employee_id': '0000001234',
    'has_password': true,
    'must_change_password': false,
  };

  test('не значок на iPhone — сервер не спрашиваем', () async {
    debugIosHomeScreenIconOverride = false;
    final (fake, paths) = server(approved);
    final ok =
        await HttpOverrides.runWithHttpOverrides(claimLoginFromSafari, fake);
    expect(ok, isFalse);
    expect(paths, isEmpty);
  });

  test('значок забирает вход из Safari и сохраняет пропуск', () async {
    debugIosHomeScreenIconOverride = true;
    final (fake, paths) = server(approved);
    final ok =
        await HttpOverrides.runWithHttpOverrides(claimLoginFromSafari, fake);
    expect(ok, isTrue);
    expect(paths, ['/api/web-handoff/claim']);
    final secure = SecureStorageHelper.instance;
    expect(await secure.isLoggedIn(), isTrue);
    expect(await secure.getToken(), 'icon-token');
    expect(await secure.getLogin(), '1234');
    expect(await secure.getFullName(), 'Иванов Иван');
    expect(await secure.hasPin(), isFalse);
  });

  test('в Safari вошли выданным кодом — значок его гасит', () async {
    debugDesktopOverride = false;
    debugIosBrowserTabOverride = false;
    debugIosHomeScreenIconOverride = true;
    final (fake, paths) =
        server({...approved, 'must_change_password': true});
    final ok =
        await HttpOverrides.runWithHttpOverrides(claimLoginFromSafari, fake);
    expect(ok, isTrue);
    expect(paths, ['/api/web-handoff/claim', '/api/account/code-used']);
  });

  test('передавать нечего — обычный экран входа', () async {
    debugIosHomeScreenIconOverride = true;
    final (fake, _) = server({'message': 'Success', 'status': 'none'});
    final ok =
        await HttpOverrides.runWithHttpOverrides(claimLoginFromSafari, fake);
    expect(ok, isFalse);
    expect(await SecureStorageHelper.instance.isLoggedIn(), isFalse);
  });

  test('куку оставляет только вкладка Safari на iPhone', () async {
    final (fake, paths) = server(approved);
    debugIosBrowserTabOverride = false;
    await HttpOverrides.runWithHttpOverrides(offerLoginToHomeScreenIcon, fake);
    expect(paths, isEmpty);
    debugIosBrowserTabOverride = true;
    await HttpOverrides.runWithHttpOverrides(offerLoginToHomeScreenIcon, fake);
    expect(paths, ['/api/web-handoff']);
  });
}
