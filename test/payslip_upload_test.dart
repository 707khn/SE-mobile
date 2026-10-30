import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/payslip_upload_screen.dart';
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
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('psu_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('psu_')).toSet();
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
}
