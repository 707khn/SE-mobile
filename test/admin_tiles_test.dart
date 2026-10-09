import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/admin_request.dart';
import 'package:se_mobile/screens/admin_employee_screen.dart';
import 'package:se_mobile/screens/admin_panel_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Строки списков администратора лежат в цветных карточках. Отклик на
/// нажатие рисуется на ближайшем Material, а им был экран под карточкой:
/// карточка его закрывала, и было не видно, что касание принято. Flutter
/// говорит об этом проверкой — она и не должна срабатывать.
void main() {
  final row = {
    'employee_id': 'ADM00001',
    'full_name': 'Тестова Админа Пробовна',
    'job_title': 'Инженер',
    'department': 'Тестовый отдел',
    'iin': '',
    'login': 'testova',
    'payslip_count': 2,
    'access_count': 5,
    'leave_count': 1,
  };

  Future<void> open(WidgetTester tester, Widget screen) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: screen,
      ));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    },
        FakeServer(200, jsonEncode({'employees': [row]}),
            contentType: 'application/json; charset=utf-8'));
  }

  testWidgets('карточка сотрудника', (tester) async {
    await open(tester,
        AdminEmployeeScreen(employee: AdminEmployee.fromJson(row)));
    expect(find.byType(ListTile), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('список сотрудников', (tester) async {
    await open(tester, const AdminPanelScreen());
    expect(find.text('Тестова Админа Пробовна'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
