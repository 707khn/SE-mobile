import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/repair_request.dart';
import 'package:se_mobile/screens/repair_request_form_screen.dart';
import 'package:se_mobile/screens/repair_requests_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Заявки на ремонт: разбор ответа сервера и экраны.
void main() {
  Map<String, dynamic> item(int id, String status,
          {bool stopped = false, double? downtime, String equipment = ''}) =>
      {
        'id': id,
        'category': 'equipment',
        'service': 'engineer',
        'place': 'Цех 1',
        'equipment': equipment,
        'description': 'Не включается',
        'phone': '',
        'stopped': stopped,
        'downtime_hours': downtime,
        'status': status,
        'author': {'id': '0000002184', 'name': 'Шаяхметов Д. Б.'},
        'assignee': null,
        'resolution': '',
        'created_at': '2026-10-22T05:00:00+00:00',
        'updated_at': '2026-10-22T05:00:00+00:00',
        'closed_at': null,
        'photo_count': 0,
      };

  group('разбор', () {
    test('заявка и очередь', () {
      final list = RepairRequestList.fromJson({
        'staff': true,
        'photos_allowed': false,
        'open': {'new': 1, 'in_progress': 2, 'stopped': 1},
        'items': [item(5, 'new', stopped: true, downtime: 2.5), 'мусор'],
        'top_equipment': [
          {'equipment': 'Пресс', 'count': 3, 'downtime_hours': 14.0}
        ],
      });
      expect(list.staff, isTrue);
      expect(list.photosAllowed, isFalse);
      expect(list.openStopped, 1);
      expect(list.items.single.stopped, isTrue);
      expect(list.items.single.downtimeHours, 2.5);
      expect(list.top.single.count, 3);
    });

    test('у каждой категории и службы есть надпись в обоих языках', () {
      final keys = LocaleString().keys;
      for (final lang in [Lang.ru, Lang.kk]) {
        for (final c in repairCategories) {
          expect(keys[lang]!.containsKey('repair_cat_$c'), isTrue, reason: c);
        }
        for (final s in ['engineer', 'facility']) {
          expect(keys[lang]!.containsKey('repair_service_$s'), isTrue,
              reason: s);
        }
        expect(keys[lang]!.keys.where((k) => k.startsWith('repair_')).length,
            keys[Lang.ru]!.keys.where((k) => k.startsWith('repair_')).length);
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
      tester.view.physicalSize = const Size(800, 1800);
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

    testWidgets('служба видит очередь, стоящее помечено', (tester) async {
      final server = FakeServer.routed((method, url, body) {
        if (url.query == 'scope=queue') {
          return (
            200,
            jsonEncode({
              'staff': true,
              'open': {'new': 1, 'in_progress': 0, 'stopped': 1},
              'items': [
                item(40, 'new',
                    stopped: true, downtime: 3, equipment: 'Токарный 16К20')
              ],
              'top_equipment': [
                {'equipment': 'Пресс КД2128', 'count': 2, 'downtime_hours': 26}
              ],
            })
          );
        }
        return (200, jsonEncode({'staff': true, 'items': []}));
      });
      await open(tester, server, const RepairRequestsScreen());
      expect(find.text('Новых: 1 · В работе: 0 · Стоит: 1'), findsOneWidget);
      expect(find.text('№40 · Токарный 16К20'), findsOneWidget);
      expect(find.text('Стоит'), findsOneWidget);
      expect(find.textContaining('Стоит уже 3 ч'), findsOneWidget);
      expect(find.text('Пресс КД2128'), findsOneWidget);
      expect(find.text('2 раз, простой 1 д 2 ч'), findsOneWidget);
    });

    testWidgets('форма: служба по выбору, «стоит» только у оборудования',
        (tester) async {
      final server = FakeServer.routed((method, url, body) =>
          (500, 'не должно было уйти'));
      await open(tester, server, const RepairRequestFormScreen());
      expect(find.text('Заявка уйдёт: Служба главного инженера'),
          findsOneWidget);
      expect(find.byKey(const Key('repair_stopped')), findsOneWidget);
      expect(find.byKey(const Key('repair_equipment')), findsOneWidget);

      await tester.tap(find.text('Сантехника, отопление'));
      await tester.pump();
      expect(find.text('Заявка уйдёт: Хозяйственный отдел'), findsOneWidget);
      expect(find.byKey(const Key('repair_stopped')), findsNothing);
      expect(find.byKey(const Key('repair_equipment')), findsNothing);

      await tester.enterText(
          find.byKey(const Key('repair_description')), 'Течёт кран');
      await tester.tap(find.byKey(const Key('repair_send')));
      await settle(tester);
      expect(find.text('Укажите, где'), findsOneWidget);
      expect(server.requests, isEmpty);
    });

    testWidgets('фото отключены — кнопок нет, есть пояснение',
        (tester) async {
      await open(tester, FakeServer(500, ''),
          const RepairRequestFormScreen(photosAllowed: false));
      expect(find.byKey(const Key('repair_photos_off')), findsOneWidget);
      expect(find.text('it_photo_camera'.tr), findsNothing);
    });

    testWidgets('место вспоминается, ответ сервера доходит',
        (tester) async {
      final server = FakeServer.routed((method, url, body) =>
          (201, jsonEncode({'message': 'Success', 'item': item(9, 'new')})));
      await open(tester, server, const RepairRequestFormScreen(),
          prefs: {'repair_last_place': 'Цех 2'});
      final place =
          tester.widget<TextField>(find.byKey(const Key('repair_place')));
      expect(place.controller!.text, 'Цех 2');
      await tester.enterText(
          find.byKey(const Key('repair_description')), 'Не крутится');
      await tester.tap(find.byKey(const Key('repair_stopped')));
      await tester.pump();
      await HttpOverrides.runWithHttpOverrides(() async {
        await tester.tap(find.byKey(const Key('repair_send')));
        await settle(tester);
      }, server);
      final sent = server.requests.single;
      expect(sent, contains('Не крутится'));
      expect(sent, contains('name="stopped"'));
      expect(sent, contains('Цех 2'));
    });
  });
}
