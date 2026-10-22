import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/on_site_request.dart';
import 'package:se_mobile/screens/on_site_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// «Сейчас на территории»: статусы, фильтры, предупреждение без СКУД.
void main() {
  Map<String, dynamic> day({String? lastEvent = '2026-10-22T09:10:00'}) => {
        'now': '09:30',
        'shift_start': '08:00',
        'last_event': lastEvent,
        'counts': {'inside': 1, 'left': 1, 'absent': 1, 'away': 1, 'late': 1},
        'people': [
          {'id': '1', 'name': 'Нет Ничего', 'status': 'absent'},
          {
            'id': '2',
            'name': 'Рано Пришёл',
            'status': 'inside',
            'first_in': '07:55'
          },
          {
            'id': '3',
            'name': 'Поздно Ушёл',
            'status': 'left',
            'first_in': '08:20',
            'last_out': '09:10',
            'late': true
          },
          {
            'id': '4',
            'name': 'В Отпуске',
            'status': 'away',
            'away': {
              'reason': 'vacation',
              'until': '2026-10-30',
              'deputy': 'Заместитель Тест'
            }
          },
        ],
      };

  test('разбор', () {
    final d = OnSiteDay.fromJson(day());
    expect(d.people.first.unknown, isTrue);
    expect(d.people[2].late, isTrue);
    expect(d.people[3].awayUntil, DateTime(2026, 10, 30));
    expect(d.count('late'), 1);
    expect(OnSiteDay.fromJson(day(lastEvent: null)).lastEvent, isNull);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru =
        keys[Lang.ru]!.keys.where((k) => k.startsWith('onsite_')).toSet();
    final kk =
        keys[Lang.kk]!.keys.where((k) => k.startsWith('onsite_')).toSet();
    expect(kk, ru);
  });

  Future<void> pump(WidgetTester tester, FakeServer server) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const OnSiteScreen(),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }, server);
  }

  testWidgets('весь отдел со статусами, фильтр «Опоздали»', (tester) async {
    await pump(tester,
        FakeServer.routed((method, url, body) => (200, jsonEncode(day()))));
    expect(find.text('Не пришёл'), findsOneWidget);
    expect(find.text('На месте с 07:55'), findsOneWidget);
    expect(find.textContaining('опоздал (08:20)'), findsOneWidget);
    expect(find.text('В отпуске до 30.10 · замещает Заместитель Тест'),
        findsOneWidget);
    expect(find.text('Последний проход через турникет — 09:10'),
        findsOneWidget);

    await tester.tap(find.byKey(const Key('onsite_filter_late')));
    await tester.pump();
    expect(find.byKey(const Key('onsite_3')), findsOneWidget);
    expect(find.byKey(const Key('onsite_1')), findsNothing);

    await tester.tap(find.byKey(const Key('onsite_filter_unknown')));
    await tester.pump();
    expect(find.byKey(const Key('onsite_1')), findsOneWidget);
    expect(find.byKey(const Key('onsite_2')), findsNothing);
  });

  testWidgets('нет событий турникета — предупреждаем', (tester) async {
    await pump(
        tester,
        FakeServer.routed(
            (method, url, body) => (200, jsonEncode(day(lastEvent: null)))));
    expect(find.textContaining('нет связи со СКУД'), findsOneWidget);
  });
}
