import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/it_request.dart' show ItPerson;
import 'package:se_mobile/requests/pre_trip_request.dart';
import 'package:se_mobile/screens/pre_trip_forms.dart';
import 'package:se_mobile/screens/pre_trip_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/role_helper.dart';

import 'support/fake_server.dart';

/// Медосмотр и выпуск: подсветка показателей, алкоголь, журнал, свой допуск.
void main() {
  const driver = ItPerson(id: '0000000155', name: 'Водитель Тест Тестович');

  Map<String, dynamic> exam({bool admitted = true, bool vitals = true}) => {
        'id': 1,
        'kind': 'pre',
        'date': '2030-01-15',
        'admitted': admitted,
        'at': '2030-01-15T02:10:00Z',
        if (vitals) ...{
          'systolic': 125,
          'diastolic': 80,
          'pulse': 72,
          'temperature': 36.6,
          'alcohol': 0,
          'reason': admitted ? '' : 'Температура 38,1',
          'warnings': [],
        },
      };

  test('разбор и границы', () {
    final day = PreTripDay.fromJson({
      'date': '2030-01-15',
      'roles': {'medic': true},
      'drivers': [
        {
          'driver': {'id': '1', 'name': 'А'},
          'status': 'admitted',
          'exam': exam(),
          'check': {'plate': '123ABC02', 'ok': true}
        }
      ],
      'counts': {'admitted': 1},
    });
    expect(day.medic, isTrue);
    expect(day.rows!.single.exam!.systolic, 125);
    expect(day.rows!.single.check!.plate, '123ABC02');
    expect(day.counts['admitted'], 1);
    const limits = PreTripLimits();
    expect(
        limits.warnings(
            systolic: 150,
            diastolic: 80,
            pulse: 45,
            temperature: 37.2,
            alcohol: 0.1),
        ['pressure', 'pulse', 'temperature', 'alcohol']);
    expect(limits.warnings(systolic: 120, diastolic: 80, alcohol: 0), isEmpty);
    expect(usesPreTrip('Водитель'), isTrue);
    expect(usesPreTrip('Медицинский работник'), isTrue);
    expect(usesPreTrip('Руководитель ДМТО'), isTrue);
    expect(usesPreTrip('Заведующий ХО'), isTrue);
    expect(usesPreTrip('Менеджер'), isFalse);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('pt_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('pt_')).toSet();
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
    tester.view.physicalSize = const Size(900, 1800);
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

  testWidgets('положительная проба не даёт допустить', (tester) async {
    final server = FakeServer.routed(
        (method, url, body) => (201, jsonEncode({'message': 'Success'})));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const PreTripExamScreen(driver: driver));
      await tester.enterText(find.byKey(const Key('pt_systolic')), '150');
      await tester.enterText(find.byKey(const Key('pt_diastolic')), '85');
      await tester.enterText(find.byKey(const Key('pt_alcohol')), '0,2');
      await tester.pump();
      expect(find.byKey(const Key('pt_warn_pressure')), findsOneWidget);
      expect(find.byKey(const Key('pt_warn_alcohol')), findsOneWidget);
      expect(
          tester
              .widget<ButtonStyleButton>(find.byKey(const Key('pt_admit')))
              .onPressed,
          isNull);
      await tester.tap(find.byKey(const Key('pt_not_admit')));
      await tester.pump();
      expect(find.text('Напишите причину'), findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('pt_reason')), 'Положительная проба');
      await tester.tap(find.byKey(const Key('pt_not_admit')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.single) as Map<String, dynamic>;
    expect(sent, {
      'employee_id': '0000000155',
      'kind': 'pre',
      'systolic': 150,
      'diastolic': 85,
      'alcohol': 0.2,
      'admitted': false,
      'reason': 'Положительная проба',
    });
  });

  testWidgets('механик выпускает машину', (tester) async {
    final server = FakeServer.routed(
        (method, url, body) => (201, jsonEncode({'message': 'Success'})));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester,
          const VehicleCheckScreen(driver: driver, lastPlate: '123ABC02'));
      await tester.enterText(find.byKey(const Key('pt_odometer')), '154200');
      await tester.tap(find.byKey(const Key('pt_vehicle_ok')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.single), {
      'employee_id': '0000000155',
      'plate': '123ABC02',
      'odometer': 154200,
      'ok': true,
    });
  });

  testWidgets('руководитель видит журнал без показателей', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'date': '2030-01-15',
            'roles': {'manager': true},
            'counts': {'admitted': 1, 'not_admitted': 1, 'pending': 0},
            'drivers': [
              {
                'driver': {'id': '1', 'name': 'Первый Водитель'},
                'status': 'admitted',
                'exam': exam(vitals: false),
                'check': {'plate': '123ABC02', 'ok': true}
              },
              {
                'driver': {'id': '2', 'name': 'Второй Водитель'},
                'status': 'not_admitted',
                'exam': exam(admitted: false, vitals: false),
              },
            ]
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const PreTripScreen());
    }, server);
    expect(find.text('Допущено: 1 · не допущено: 1 · ждут: 0'), findsOneWidget);
    expect(find.text('Не допущен'), findsOneWidget);
    expect(find.textContaining('Давление'), findsNothing);
    expect(find.textContaining('38,1'), findsNothing);
    // Ни осмотра, ни выпуска — руководитель только смотрит.
    expect(find.byKey(const Key('pt_exam_1')), findsNothing);
    expect(find.byKey(const Key('pt_check_1')), findsNothing);
  });

  testWidgets('водитель видит свой допуск', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'date': '2030-01-15',
            'roles': {'driver': true},
            'me': {
              'status': 'admitted',
              'exam': exam(),
              'check': {'plate': '123ABC02', 'ok': true},
              'history': [exam()],
            }
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const PreTripScreen());
    }, server);
    expect(find.text('Допущен к рейсу'), findsOneWidget);
    expect(find.text('Давление 125/80 · пульс 72 · 36,6 °C · алкоголь 0'),
        findsNWidgets(2));
    expect(find.byKey(const Key('pt_date')), findsNothing);
  });
}
