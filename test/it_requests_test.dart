import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/it_request.dart';
import 'package:se_mobile/screens/it_request_form_screen.dart';
import 'package:se_mobile/screens/it_requests_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/widgets/load_error_view.dart';

import 'support/fake_server.dart';

/// Заявки в ОИТиС: разбор ответа сервера и экраны.
void main() {
  Map<String, dynamic> item(int id, String status,
          {String room = '305', Map<String, dynamic>? assignee}) =>
      {
        'id': id,
        'category': 'printer',
        'room': room,
        'description': 'Не печатает',
        'phone': '',
        'status': status,
        'author': {
          'id': '0000002184',
          'name': 'Шаяхметов Ерлан Маратович',
          'department': 'Руководство'
        },
        'assignee': assignee,
        'resolution': '',
        'created_at': '2026-10-22T05:00:00+00:00',
        'updated_at': '2026-10-22T05:00:00+00:00',
        'closed_at': null,
        'photo_count': 2,
      };

  group('разбор', () {
    test('заявка из списка', () {
      final r = ItRequest.fromJson(item(7, 'in_progress', assignee: {
        'id': '0000001668',
        'name': 'Николаев Даниил Олегович',
      }));
      expect(r.id, 7);
      expect(r.isOpen, isTrue);
      expect(r.photoCount, 2);
      expect(r.assignee!.short, 'Николаев Д. О.');
      expect(r.createdAt!.isUtc, isFalse);
    });

    test('«не помогло» — только две недели после выполнения', () {
      final fresh = ItRequest.fromJson({
        ...item(1, 'done'),
        'closed_at': DateTime.now().toUtc().toIso8601String(),
      });
      final old = ItRequest.fromJson({
        ...item(2, 'done'),
        'closed_at': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 20))
            .toIso8601String(),
      });
      expect(fresh.canReopen, isTrue);
      expect(old.canReopen, isFalse);
      expect(ItRequest.fromJson(item(3, 'rejected')).canReopen, isFalse);
    });

    test('кривой ответ не роняет разбор', () {
      final list = ItRequestList.fromJson({
        'items': [item(1, 'new'), 'мусор', 42],
        'it_staff': 'да',
        'open': 'нет',
      });
      expect(list.items.single.id, 1);
      expect(list.itStaff, isFalse);
      expect(list.openNew, 0);
    });

    test('у каждой категории и статуса есть надпись в обоих языках', () {
      final keys = LocaleString().keys;
      for (final lang in [Lang.ru, Lang.kk]) {
        for (final c in itCategories) {
          expect(keys[lang]!.containsKey('it_cat_$c'), isTrue, reason: c);
        }
        for (final s in ['new', 'in_progress', 'done', 'rejected', 'cancelled']) {
          expect(keys[lang]!.containsKey('it_status_$s'), isTrue, reason: s);
        }
        for (final a in [
          'created', 'take', 'done', 'reject', 'cancel', 'reopen', 'comment'
        ]) {
          expect(keys[lang]!.containsKey('it_ev_$a'), isTrue, reason: a);
        }
      }
    });
  });

  group('экраны', () {
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }

    Future<void> open(WidgetTester tester, FakeServer server, Widget home,
        {Map<String, Object> prefs = const {}}) async {
      // Форма длинная: кнопка «Отправить» должна поместиться на экран.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(Lang.initDates);
      SharedPreferences.setMockInitialValues(prefs);
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

    testWidgets('сотрудник видит свои заявки, без очереди', (tester) async {
      final server = FakeServer.routed((method, url, body) {
        expect(url.query, isEmpty, reason: 'очередь спрашивать незачем');
        return (200, jsonEncode({'it_staff': false, 'items': [item(12, 'new')]}));
      });
      await open(tester, server, const ItRequestsScreen());
      expect(find.text('№12 · Кабинет 305'), findsOneWidget);
      expect(find.text('Новая'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
    });

    testWidgets('ОИТиС видит очередь первой вкладкой', (tester) async {
      final server = FakeServer.routed((method, url, body) {
        if (url.query == 'scope=queue') {
          return (
            200,
            jsonEncode({
              'it_staff': true,
              'open': {'new': 2, 'in_progress': 1},
              'items': [item(30, 'new', room: '101'), item(31, 'new')],
            })
          );
        }
        return (200, jsonEncode({'it_staff': true, 'items': []}));
      });
      await open(tester, server, const ItRequestsScreen());
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.text('Очередь (2)'), findsOneWidget);
      expect(find.text('Новых: 2 · В работе: 1'), findsOneWidget);
      expect(find.text('№30 · Кабинет 101'), findsOneWidget);
    });

    testWidgets('список не загрузился — ошибка, а не «заявок нет»',
        (tester) async {
      await open(tester, FakeServer(502, 'Bad Gateway'),
          const ItRequestsScreen());
      expect(find.byType(LoadErrorView), findsOneWidget);
      expect(find.text('it_empty_mine'.tr), findsNothing);
    });

    testWidgets('без кабинета не отправляется', (tester) async {
      final server = FakeServer.routed((method, url, body) =>
          (500, 'не должно было уйти'));
      await open(tester, server, const ItRequestFormScreen());
      await tester.enterText(
          find.byKey(const Key('it_description')), 'Не печатает');
      await tester.tap(find.byKey(const Key('it_send')));
      await settle(tester);
      expect(find.text('Укажите кабинет'), findsOneWidget);
      expect(server.requests, isEmpty);
    });

    testWidgets('кабинет вспоминается, отказ сервера — понятным текстом',
        (tester) async {
      final server = FakeServer.routed((method, url, body) =>
          (429, jsonEncode({'message': 'Failure', 'error': 'too_many_open'})));
      await open(tester, server, const ItRequestFormScreen(),
          prefs: {'it_last_room': '412'});
      final room = tester.widget<TextField>(find.byKey(const Key('it_room')));
      expect(room.controller!.text, '412');

      await tester.enterText(
          find.byKey(const Key('it_description')), 'Нет сети');
      await HttpOverrides.runWithHttpOverrides(() async {
        await tester.tap(find.byKey(const Key('it_send')));
        await settle(tester);
      }, server);
      expect(server.requests.single, contains('Нет сети'));
      expect(find.byKey(const Key('it_error')), findsOneWidget);
      expect(find.textContaining('много открытых заявок'), findsOneWidget);
      // Набранное осталось.
      expect(find.text('Нет сети'), findsOneWidget);
    });
  });
}
