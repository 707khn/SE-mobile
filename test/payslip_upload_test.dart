import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/payslip_upload_screen.dart';
import 'package:se_mobile/screens/payslips_admin_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/role_helper.dart';

import 'support/fake_server.dart';

/// Загрузка листков из 1С: файл → что в нём → «Опубликовать» → готово.
void main() {
  Map<String, dynamic> summary({bool dryRun = true, int replaced = 0}) => {
        'message': 'Success',
        if (dryRun) 'dry_run': true,
        if (!dryRun) 'imported': 374,
        'periods': ['Июль 2026'],
        'count': 374,
        'new': 374 - replaced,
        'replaced': replaced,
        'unknown': [
          {'employee_id': '0000002131', 'full_name': 'Новенький Нов Новович'},
        ],
      };

  Future<PickedFile?> pick() async =>
      (name: 'Июль.xls', bytes: Uint8List.fromList([1, 2, 3]));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: home,
    ));
    await settle(tester);
  }

  test('кто загружает', () {
    expect(isPayroll('Бухгалтер расчетной группы'), isTrue);
    expect(isPayroll('Бухгалтер расчётной группы'), isTrue);
    expect(isPayroll('Главный бухгалтер'), isTrue);
    expect(isPayroll('Бухгалтер'), isFalse);
    expect(isPayroll('Заместитель главного бухгалтера'), isFalse);
    expect(canUploadPayslips('Администратор системы'), isTrue);

    // Открыли списком на сервере — должность в справочнике та же.
    expect(canUploadPayslips('Бухгалтер'), isFalse);
    PayrollAccess.granted.value = true;
    addTearDown(() => PayrollAccess.granted.value = false);
    expect(canUploadPayslips('Бухгалтер'), isTrue);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    bool ours(String k) => k.startsWith('psu_') || k.startsWith('psa_');
    final ru = keys[Lang.ru]!.keys.where(ours).toSet();
    final kk = keys[Lang.kk]!.keys.where(ours).toSet();
    expect(kk, ru);
  });

  testWidgets('сначала проверка, публикация — после подтверждения',
      (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode(summary(dryRun: body.contains('name="dry_run"')))
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, PayslipUploadScreen(pick: pick));
      await tester.tap(find.byKey(const Key('psu_choose')));
      await settle(tester);

      expect(server.requests, hasLength(1));
      expect(server.requests.single, contains('name="dry_run"'));
      expect(server.requests.single, contains('filename="Июль.xls"'));
      expect(find.text('Июль 2026'), findsOneWidget);
      expect(find.text('374'), findsOneWidget);
      expect(find.text('Нет в приложении: 1'), findsOneWidget);

      await tester.tap(find.byKey(const Key('psu_publish')));
      await tester.pumpAndSettle();
      expect(server.requests, hasLength(1), reason: 'без подтверждения — ничего');
      await tester.tap(find.byKey(const Key('psu_confirm')));
      await settle(tester);
    }, server);
    expect(server.requests, hasLength(2));
    expect(server.requests.last, isNot(contains('name="dry_run"')));
    expect(find.text('Июль 2026: опубликовано 374 листков'), findsOneWidget);
  });

  testWidgets('перевыгрузка месяца — предупреждение о замене', (tester) async {
    final server = FakeServer.routed(
        (method, url, body) => (200, jsonEncode(summary(replaced: 374))));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, PayslipUploadScreen(pick: pick));
      await tester.tap(find.byKey(const Key('psu_choose')));
      await settle(tester);
    }, server);
    expect(find.text('Заменят загруженные раньше'), findsOneWidget);
  });

  testWidgets('не тот файл — слова сервера', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          422,
          jsonEncode({
            'message': 'В файле нет расчётных листков.',
            'error': true
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, PayslipUploadScreen(pick: pick));
      await tester.tap(find.byKey(const Key('psu_choose')));
      await settle(tester);
    }, server);
    expect(find.byKey(const Key('psu_error')), findsOneWidget);
    expect(find.text('В файле нет расчётных листков.'), findsOneWidget);
    expect(find.byKey(const Key('psu_publish')), findsNothing);
  });

  testWidgets('раздел: месяцы → листки месяца → удалить листок',
      (tester) async {
    final calls = <String>[];
    final server = FakeServer.routed((method, url, body) {
      calls.add('$method ${url.path}');
      if (method == 'DELETE') {
        return (200, jsonEncode({'message': 'Success', 'deleted': 1}));
      }
      if (url.path.endsWith('/periods')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'items': [
              {
                'year': 2026,
                'month': 7,
                'title': 'Июль 2026',
                'count': 374,
                'uploaded': {
                  'at': '2026-10-30T11:40:00+00:00',
                  'by': 'Бухгалтер Тест',
                  'file': 'Июль.xls',
                  'count': 374
                }
              }
            ]
          })
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'items': [
            {
              'employee_id': '0000001874',
              'full_name': 'Тестов Тест Тестович',
              'department': 'Отдел тестирования',
              'net_pay': 245000.0
            },
            {
              'employee_id': '0000002002',
              'full_name': 'Другой Друг Другович',
              'department': 'АУП',
              'net_pay': 100000.0
            },
          ]
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const PayslipsAdminScreen());
      expect(find.text('Июль 2026'), findsOneWidget);
      expect(find.textContaining('Листков: 374'), findsOneWidget);
      expect(find.byKey(const Key('psa_add')), findsOneWidget);

      await tester.tap(find.byKey(const Key('psa_period_2026_7')));
      await settle(tester);
      await tester.pumpAndSettle();
      expect(find.text('Тестов Тест Тестович'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('psa_search')), 'друг');
      await tester.pump();
      expect(find.text('Тестов Тест Тестович'), findsNothing);
      expect(find.text('Другой Друг Другович'), findsOneWidget);

      await tester.tap(find.byKey(const Key('psa_menu_0000002002')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить листок'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('psa_confirm')));
      await settle(tester);
    }, server);
    expect(calls, contains('DELETE /api/payslips/periods/2026/7/0000002002'));
  });
}
