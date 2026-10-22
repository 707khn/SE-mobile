import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/medical_request.dart';
import 'package:se_mobile/screens/medical_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Медосмотры: свои сроки, запись на свободное время, приём медпункта.
void main() {
  Map<String, dynamic> slot(int id, String at,
          {String kind = 'exam', Map<String, dynamic>? employee}) =>
      {
        'id': id,
        'kind': kind,
        'starts_at': at,
        'booked': employee != null,
        'mine': false,
        'employee': employee,
      };

  final worker = {
    'id': '0000000082',
    'name': 'Мастеров Иван',
    'job_title': 'Мастер',
    'department': 'Основное производство (ОП)'
  };

  test('разбор', () {
    final mine = MedicalMine.fromJson({
      'medic': false,
      'exams': [
        {'id': 1, 'kind': 'periodic', 'due_on': '2030-02-01', 'state': 'soon'}
      ],
      'free': [slot(4, '2030-01-16T09:20')],
    });
    expect(mine.exams.single.dueOn, DateTime(2030, 2, 1));
    expect(mine.free.single.startsAt, DateTime(2030, 1, 16, 9, 20));
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('md_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('md_')).toSet();
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
    tester.view.physicalSize = const Size(900, 2200);
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

  testWidgets('сотрудник видит срок и записывается', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (200, jsonEncode({'message': 'Success', 'slot': slot(4, 'x')}))
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'medic': false,
              'exams': [
                {
                  'id': 1,
                  'kind': 'fluorography',
                  'due_on': '2030-01-10',
                  'last_done_on': '2029-01-09',
                  'state': 'overdue'
                }
              ],
              'bookings': [],
              'free': [
                slot(4, '2030-01-16T09:20'),
                slot(5, '2030-01-17T10:00', kind: 'vaccination'),
              ],
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const MedicalScreen());
      expect(tester.widget<Text>(find.byKey(const Key('md_due_1'))).data,
          'Пройти до 10.01.2030 · Срок прошёл');
      expect(find.text('Последний раз: 09.01.2029'), findsOneWidget);
      expect(find.text('17.01.2030'), findsOneWidget);
      expect(find.byType(TabBar), findsNothing);
      await tester.tap(find.byKey(const Key('md_slot_4')));
      await tester.pumpAndSettle();
      expect(find.text('Записаться на 16.01.2030 в 09:20?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('md_confirm')));
      await settle(tester);
    }, server);
    expect(server.requests.length, greaterThanOrEqualTo(2));
    expect(find.text('Вы записаны'), findsOneWidget);
  });

  testWidgets('медпункт открывает время и отмечает пройденное', (tester) async {
    final urls = <String>[];
    final server = FakeServer.routed((method, url, body) {
      urls.add('$method ${url.path}');
      if (url.path.endsWith('/desk')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'slots': [slot(8, '2030-01-15T09:00', employee: worker)],
            'due': [
              {
                'id': 3,
                'kind': 'periodic',
                'due_on': '2030-01-20',
                'state': 'soon',
                'employee': worker
              }
            ],
          })
        );
      }
      if (method == 'POST') {
        return (201, jsonEncode({'message': 'Success', 'added': 8}));
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'medic': true,
          'exams': [],
          'bookings': [],
          'free': []
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, MedicalScreen(today: DateTime(2030, 1, 15)));
      await tester.tap(find.text('Медпункт'));
      await tester.pumpAndSettle();
      expect(find.text('Приём 15.01.2030'), findsOneWidget);
      expect(find.text('Осмотр · Мастеров Иван'), findsOneWidget);

      await tester.tap(find.byKey(const Key('md_open_slots')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('md_kind_vaccination')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fields_ok')));
      await settle(tester);
      expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)), {
        'date': '2030-01-15',
        'kind': 'vaccination',
        'from': '09:00',
        'to': '11:00',
        'step': '15',
      });
      expect(find.text('Открыто: 8'), findsOneWidget);

      await tester.tap(find.byKey(const Key('md_done_3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('md_confirm')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)),
        {'action': 'done'});
    expect(urls, contains('POST /api/medical/exams/3'));
  });
}
