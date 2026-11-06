import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/telegram_request.dart';
import 'package:se_mobile/screens/settings_screen.dart';
import 'package:se_mobile/screens/telegram_screen.dart';
import 'package:se_mobile/utils/biometric.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/widgets/load_error_view.dart';

import 'support/fake_server.dart';

class _NoSensor implements Biometric {
  @override
  Future<bool> available() async => false;

  @override
  Future<bool> authenticate(String reason) async => false;
}

/// Сервер понарошку: бот заведён или нет, Telegram подключён или нет, и что
/// у него просили.
class _Bot {
  bool enabled = true;
  bool linked = false;
  final List<String> asked = [];

  late final FakeServer server = FakeServer.routed((method, url, body) {
    if (!url.path.startsWith('/api/telegram')) return (404, '{}');
    asked.add('$method ${url.path}');
    if (method == 'POST' && url.path == '/api/telegram/link') {
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'url': 'https://t.me/se_mobile_bot?start=abc',
          'expires_in': 1800,
        })
      );
    }
    if (method == 'DELETE') {
      linked = false;
      return (200, jsonEncode({'message': 'Success', 'linked': false}));
    }
    return (
      200,
      jsonEncode(
          {'message': 'Success', 'enabled': enabled, 'linked': linked})
    );
  });
}

/// Уведомления в Telegram — для веб-версии, где пуша нет.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    Biometric.instance = _NoSensor();
  });

  tearDown(() => debugTelegramOfferedOverride = null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester
          .runAsync(() => Future.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester, _Bot bot, Widget home) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: home,
      ));
      await settle(tester);
    }, bot.server);
  }

  /// Нажать и дождаться ответа сервера — с тем же сервером понарошку.
  Future<void> tap(WidgetTester tester, _Bot bot, Finder target) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(target);
      await settle(tester);
    }, bot.server);
  }

  test('без бота на сервере «подключено» не бывает', () {
    final state = TelegramState.fromJson({'enabled': false, 'linked': true});
    expect(state.enabled, isFalse);
    expect(state.linked, isFalse);
  });

  testWidgets('подключить: ссылка на бота, «Запустить» — и подключено',
      (tester) async {
    final bot = _Bot();
    await open(tester, bot, const TelegramScreen());
    expect(find.text('Подключить Telegram'), findsOneWidget);

    await tap(tester, bot, find.text('Подключить Telegram'));
    expect(bot.asked, contains('POST /api/telegram/link'));
    expect(find.text('Открыть Telegram'), findsOneWidget);
    expect(find.text('Скопировать ссылку'), findsOneWidget);
    expect(find.textContaining('30 минут'), findsOneWidget);

    // Человек нажал «Запустить» в Telegram — экран узнаёт сам.
    bot.linked = true;
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
    }, bot.server);
    expect(find.text('Telegram подключён'), findsOneWidget);
    expect(find.text('Готово: Telegram подключён'), findsOneWidget);
    expect(find.text('Открыть Telegram'), findsNothing);
  });

  testWidgets('отключить — с вопросом, и сервер отвязывает',
      (tester) async {
    final bot = _Bot()..linked = true;
    await open(tester, bot, const TelegramScreen());
    expect(find.text('Telegram подключён'), findsOneWidget);

    // Запрос уходит после вопроса, но из того же касания — поэтому и
    // касание, и ответ на вопрос — с тем же сервером понарошку.
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.text('Отключить'));
      await tester.pumpAndSettle();
      expect(find.text('Отключить уведомления в Telegram?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Отключить'));
      await settle(tester);
    }, bot.server);
    expect(bot.asked, contains('DELETE /api/telegram'));
    expect(bot.linked, isFalse);
    expect(find.text('Подключить Telegram'), findsOneWidget);
    expect(find.text('Уведомления в Telegram отключены'), findsOneWidget);
  });

  testWidgets('сервер не ответил — ошибка и повтор, а не пустой экран',
      (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const TelegramScreen(),
      ));
      await settle(tester);
    }, FakeServer(502, 'Bad Gateway'));
    expect(find.byType(LoadErrorView), findsOneWidget);
    expect(find.text('try_again'.tr), findsOneWidget);
    expect(find.text('Подключить Telegram'), findsNothing);
  });

  group('в «Настройках»', () {
    testWidgets('в браузере и с ботом на сервере — строка есть',
        (tester) async {
      debugTelegramOfferedOverride = true;
      final bot = _Bot();
      await open(tester, bot, const SettingsScreen());
      expect(find.text('Уведомления в Telegram'), findsOneWidget);
      expect(find.text('Выключены'), findsOneWidget);
    });

    testWidgets('бота на сервере нет — строки нет', (tester) async {
      debugTelegramOfferedOverride = true;
      final bot = _Bot()..enabled = false;
      await open(tester, bot, const SettingsScreen());
      expect(find.text('Уведомления в Telegram'), findsNothing);
    });

    testWidgets('на телефоне есть пуш — строки нет, и сервер не спрашиваем',
        (tester) async {
      debugTelegramOfferedOverride = false;
      final bot = _Bot();
      await open(tester, bot, const SettingsScreen());
      expect(find.text('Уведомления в Telegram'), findsNothing);
      expect(bot.asked, isEmpty);
    });
  });
}
