import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/notifications_request.dart';
import 'package:se_mobile/screens/notifications_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/notice_badge.dart';
import 'package:se_mobile/widgets/load_error_view.dart';
import 'package:se_mobile/widgets/notification_bell.dart';

import 'support/fake_server.dart';

/// Оповещения в приложении: колокольчик и лента.
void main() {
  group('разбор ответа', () {
    test('свежие сверху, кривые строки пропускаются', () {
      final feed = NoticeFeed.fromJson({
        'items': [
          {'id': 3, 'kind': 'menu', 'title': 'Столовая', 'body': 'Меню'},
          'мусор',
          {'kind': 'news', 'title': 'без номера'},
          {
            'id': 7,
            'kind': 'payslip',
            'title': 'Зарплата',
            'body': 'Расчётный лист за сентябрь 2026 готов',
            'unread': true,
            'created_at': '2026-10-22T06:00:00+00:00',
          },
        ],
        'system': [
          {'key': 'backup', 'title': 'Копий базы нет', 'body': ''},
          {'key': 'empty', 'title': ''},
        ],
        'unread': 1,
      });
      expect(feed.items.map((n) => n.id), [7, 3]);
      expect(feed.newestId, 7);
      expect(feed.items.first.unread, isTrue);
      expect(feed.items.first.createdAt, DateTime.utc(2026, 10, 22, 6));
      expect(feed.items.last.unread, isFalse);
      expect(feed.system.map((p) => p.key), ['backup']);
      expect(feed.unread, 1);
    });

    test('пустой ответ — пустая лента, а не падение', () {
      final feed = NoticeFeed.fromJson({});
      expect(feed.items, isEmpty);
      expect(feed.system, isEmpty);
      expect(feed.newestId, isNull);
    });
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester
          .runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, FakeServer server, Widget home) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: home,
      ));
      await settle(tester);
    }, server);
  }

  testWidgets('открыл ленту — прочитал, и колокольчик гаснет', (tester) async {
    NoticeBadge.count.value = 2;
    final seen = <String>[];
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST' && url.path == '/api/notifications/seen') {
        seen.add(body);
        return (200, jsonEncode({'message': 'Success', 'unread': 0}));
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'unread': 2,
          'system': [],
          'items': [
            {
              'id': 12,
              'kind': 'payslip',
              'title': 'Зарплата',
              'body': 'Расчётный лист за сентябрь 2026 готов',
              'unread': true,
            },
            {
              'id': 9,
              'kind': 'news',
              'title': 'Объявление',
              'body': 'Отключение воды',
              'unread': true,
            },
          ],
        })
      );
    });
    await pump(tester, server, const NotificationsScreen());

    expect(find.text('Расчётный лист за сентябрь 2026 готов'), findsOneWidget);
    expect(find.text('Отключение воды'), findsOneWidget);
    expect(seen, hasLength(1));
    expect(jsonDecode(seen.single), {'last_id': 12});
    expect(NoticeBadge.count.value, 0);
  });

  testWidgets('администратору — поломки сервера, и они не гасятся',
      (tester) async {
    NoticeBadge.count.value = 0;
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'unread': 0,
            'items': [],
            'system': [
              {
                'key': 'backup',
                'title': 'Копия базы не обновляется',
                'body': 'Последняя — 2026-10-18, 4 дн. назад.',
              },
            ],
          })
        ));
    await pump(tester, server,
        const NotificationsScreen(job: 'Администратор системы'));

    expect(find.text('notices_system'.tr), findsOneWidget);
    expect(find.text('Копия базы не обновляется'), findsOneWidget);
    // Прочитать поломку нельзя — её можно только починить.
    expect(NoticeBadge.count.value, 1);
  });

  testWidgets('лента не загрузилась — ошибка, а не «ничего нового»',
      (tester) async {
    await pump(
        tester, FakeServer(502, 'Bad Gateway'), const NotificationsScreen());
    expect(find.byType(LoadErrorView), findsOneWidget);
    expect(find.text('notices_empty'.tr), findsNothing);
  });

  testWidgets('пусто — так и сказано', (tester) async {
    await pump(
        tester,
        FakeServer(
            200, jsonEncode({'message': 'Success', 'items': [], 'unread': 0})),
        const NotificationsScreen());
    expect(find.text('notices_empty'.tr), findsOneWidget);
  });

  testWidgets('на колокольчике число, а 0 не показывается', (tester) async {
    NoticeBadge.count.value = 0;
    await pump(tester, FakeServer(200, '{}'),
        const Scaffold(body: NotificationBell(job: '')));
    expect(find.byIcon(Icons.notifications_none), findsOneWidget);
    expect(find.text('0'), findsNothing);

    NoticeBadge.count.value = 3;
    await tester.pump();
    expect(find.byIcon(Icons.notifications), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    NoticeBadge.count.value = 150;
    await tester.pump();
    expect(find.text('99+'), findsOneWidget);
    NoticeBadge.reset();
  });
}
