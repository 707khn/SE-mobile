import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/work_permit_request.dart';
import 'package:se_mobile/screens/work_permit_detail_screen.dart';
import 'package:se_mobile/screens/work_permit_form_screen.dart';
import 'package:se_mobile/screens/work_permits_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Наряд-допуск: форма с мерами, согласование, допуск, доска.
void main() {
  Map<String, dynamic> permit(int id, String status,
          {Map<String, bool> can = const {}, bool overdue = false}) =>
      {
        'id': id,
        'kind': 'fire',
        'place': 'Цех 1, участок сварки',
        'work': 'Сварка рамы стенда',
        'starts_at': '2030-01-15T09:00',
        'ends_at': '2030-01-15T17:00',
        'members': ['Иванов И.', 'Петров П.'],
        'measures': ['Убрать горючие материалы'],
        'status': status,
        'reason': '',
        'overdue': overdue,
        'expired': false,
        'issuer': {'id': '0000000082', 'name': 'Мастер Тест'},
        'responsible': {'id': '0000000082', 'name': 'Мастер Тест'},
        'performer': {'id': '0000000150', 'name': 'Сварщиков Пётр'},
        'admitter': {'id': '0000000631', 'name': 'Энергетик Тест'},
        'approver': null,
        'events': [
          {
            'action': 'created',
            'at': '2030-01-15T03:00:00Z',
            'actor': {'id': '0000000082', 'name': 'Мастер Тест'}
          }
        ],
        for (final e in can.entries) 'can_${e.key}': e.value,
      };

  test('разбор и время предприятия', () {
    final item = WorkPermit.fromJson(permit(1, 'open', overdue: true));
    expect(item.startsAt, DateTime(2030, 1, 15, 9));
    expect(workPermitSpan(item), '15.01 09:00 – 17:00');
    expect(item.overdue, isTrue);
    expect(permitTime(DateTime(2030, 1, 5, 7, 3)), '2030-01-05T07:03');
    final list = WorkPermitList.fromJson({
      'can_issue': true,
      'measures': {
        'fire': ['А', 3, 'Б'],
      },
      'items': [permit(1, 'pending'), 'мусор'],
    });
    expect(list.measures['fire'], ['А', 'Б']);
    expect(list.items.single.id, 1);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('wp_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('wp_')).toSet();
    expect(kk, ru);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester
          .runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: home,
    ));
    await settle(tester);
  }

  testWidgets('мастер выписывает огневые с мерами и бригадой', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.path.endsWith('/people')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'people': [
              {
                'id': '0000000150',
                'name': 'Сварщиков Пётр',
                'job_title': 'Мастер'
              }
            ]
          })
        );
      }
      return (
        201,
        jsonEncode({'message': 'Success', 'item': permit(9, 'pending')})
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(
          tester,
          WorkPermitFormScreen(
            now: DateTime(2030, 1, 15, 8, 20),
            measures: const {
              'fire': ['Убрать горючие материалы', 'Огнетушитель'],
              'height': ['Ограждение'],
            },
          ));
      expect(find.text('15.01.2030 09:00'), findsOneWidget);
      expect(find.text('15.01.2030 17:00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('wp_kind_height')));
      await tester.pump();
      expect(find.text('Огнетушитель'), findsNothing);
      await tester.tap(find.byKey(const Key('wp_kind_fire')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('wp_place')), 'Цех 1, участок сварки');
      await tester.enterText(
          find.byKey(const Key('wp_work')), 'Сварка рамы стенда');
      await tester.tap(find.byKey(const Key('wp_send')));
      await tester.pump();
      expect(find.text('Выберите производителя работ'), findsOneWidget);

      await tester.tap(find.byKey(const Key('wp_pick_performer')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('person_0000000150')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('wp_members')), 'Иванов И.\n\nПетров П.');
      // Огнетушитель снят, своя мера добавлена.
      await tester.tap(find.text('Огнетушитель'));
      await tester.enterText(
          find.byKey(const Key('wp_measure_text')), 'Наблюдающий');
      await tester.tap(find.byKey(const Key('wp_measure_add')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('wp_send')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.last), {
      'kind': 'fire',
      'place': 'Цех 1, участок сварки',
      'work': 'Сварка рамы стенда',
      'starts_at': '2030-01-15T09:00',
      'ends_at': '2030-01-15T17:00',
      'performer_id': '0000000150',
      'members': ['Иванов И.', 'Петров П.'],
      'measures': ['Убрать горючие материалы', 'Наблюдающий'],
    });
  });

  testWidgets('БиОТ согласует', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({'message': 'Success', 'item': permit(4, 'approved')})
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item': permit(4, 'pending', can: {'approve': true})
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const WorkPermitDetailScreen(permitId: 4));
      expect(find.text('Сварщиков Пётр'), findsOneWidget);
      expect(find.text('• Петров П.'), findsOneWidget);
      expect(find.byKey(const Key('wp_admit')), findsNothing);
      await tester.tap(find.byKey(const Key('wp_approve')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('prompt_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(jsonDecode(server.requests.last), {'action': 'approve'});
    expect(find.text('Согласован'), findsOneWidget);
    expect(find.byKey(const Key('wp_approve')), findsNothing);
  });

  testWidgets('допускающий допускает, просроченный — с предупреждением',
      (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': permit(5, 'open', overdue: true)
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item': permit(5, 'approved', can: {'admit': true})
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const WorkPermitDetailScreen(permitId: 5));
      expect(find.byKey(const Key('wp_alarm')), findsNothing);
      await tester.tap(find.byKey(const Key('wp_admit')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.last), {'action': 'admit'});
    expect(find.byKey(const Key('wp_alarm')), findsOneWidget);
  });

  testWidgets('у БиОТ — очередь, доска и свои', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      final scope = url.queryParameters['scope'];
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'can_issue': false,
          'safety': true,
          'board': true,
          'waiting': 2,
          'items': [
            if (scope == 'queue') permit(1, 'pending'),
            if (scope == 'board') permit(2, 'open'),
          ],
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const WorkPermitsScreen());
    }, server);
    expect(find.text('На согласование (2)'), findsOneWidget);
    expect(find.text('Сейчас идут'), findsOneWidget);
    expect(find.text('Ждёт БиОТ'), findsOneWidget);
    expect(find.byKey(const Key('wp_new')), findsNothing);
  });
}
