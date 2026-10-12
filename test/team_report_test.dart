import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/main_screen_2.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';
import 'support/real_fonts.dart';

/// Отчёт начальника по отделу показывает проходы того, чья фамилия над ними,
/// и за те дни, что выбраны.
///
/// Прежде список фамилий возвращался с прошлого раза, а проходы — нет; после
/// удаления из списка под фамилией одного стояли проходы другого, а после
/// смены дат — проходы за прежние дни под новыми датами.
const _first = 'Тестов Аман';
const _second = 'Пробная Бибігүл';

/// Сервер отвечает каждому своё: у каждого — своя проходная.
FakeServer _server() => FakeServer.routed((method, url, body) {
      if (!url.path.endsWith('/director_report')) {
        return (200, jsonEncode({'message': 'Success'}));
      }
      final ask = jsonDecode(body) as Map<String, dynamic>;
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'director_report': [
            {
              'date': ask['start_date'],
              'time': '08:01',
              'event': 'Вход',
              'door': 'Проходная ${ask['emp_sname']}',
            }
          ],
          'coverage': {
            'employee_has_any': true,
            'employee_until': ask['end_date'],
            'loaded_until': ask['end_date'],
          },
        })
      );
    });

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  setUpAll(realFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'emp_snames': [_first, _second],
    });
    FlutterSecureStorage.setMockInitialValues({'employeeId': 'TEST0001'});
  });

  // Узкий телефон: строка «Выбрать сотрудника · 2 · Очистить всё» на нём
  // не помещалась, и кнопка уходила за край.
  Future<FakeServer> open(WidgetTester tester, {String lang = 'ru'}) async {
    await tester.runAsync(Lang.initDates);
    tester.view.physicalSize = const Size(320, 2400) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    final server = _server();
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: Locale(lang),
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const MainPage2(fullName: 'Начальников Тест', job: 'Начальник'),
      ));
      await _settle(tester);
    }, server);
    return server;
  }

  for (final lang in ['ru', 'kk']) {
    testWidgets('список вернулся с прошлого раза — показан последний ($lang)',
        (tester) async {
      await open(tester, lang: lang);
      expect(find.textContaining('Проходная $_second'), findsWidgets);
      expect(find.textContaining('Проходная $_first'), findsNothing);
    });
  }

  testWidgets('после удаления последнего — проходы нового последнего',
      (tester) async {
    final server = await open(tester);
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.drag(find.widgetWithText(Dismissible, _second),
          const Offset(-600, 0));
      await _settle(tester);
    }, server);
    expect(find.textContaining('Проходная $_first'), findsWidgets);
    expect(find.textContaining('Проходная $_second'), findsNothing);
  });

  testWidgets('после смены дат проходы — за новые дни', (tester) async {
    final server = await open(tester);
    final now = DateTime.now();
    final first = DateTime(now.year, now.month - 1, 1);
    final day = '${first.year}-${first.month.toString().padLeft(2, '0')}-01';
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.ensureVisible(find.text('last_month'.tr));
      await tester.pump();
      await tester.tap(find.text('last_month'.tr));
      await _settle(tester);
    }, server);
    final asked = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(asked['emp_sname'], _second);
    expect(asked['start_date'], day);
  });

  testWidgets('второй раз открытый отчёт — поиск без ошибок в журнале',
      (tester) async {
    // Поле поиска было общим на все открытия экрана, и каждое открытие
    // вешало на него своего слушателя, а закрытие не снимало. Со второго
    // открытия каждая буква в поиске будила закрытый экран — и в журнал
    // «О программе» падала ошибка на каждое нажатие.
    final server = await open(tester);
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const MainPage2(fullName: 'Начальников Тест', job: 'Начальник'),
      ));
      await _settle(tester);
      await tester.tap(find.widgetWithText(ElevatedButton, 'search'.tr));
      await _settle(tester);
      await tester.enterText(find.byType(TextField).last, 'Тес');
      await _settle(tester);
    }, server);
    expect(tester.takeException(), isNull);
  });
}
