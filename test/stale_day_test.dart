import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/menu_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Ответ за прежний день, пришедший позже, на экран не попадает.
///
/// Стрелки работают и пока день грузится. В столовой, где связь то есть, то
/// нет, ответ за среду мог прийти позже ответа за четверг — и под
/// «четвергом» стояло меню среды.
void main() {
  String day(int back) => DateFormat('yyyy-MM-dd')
      .format(DateTime.now().subtract(Duration(days: back)));

  /// На запрос за вчера сервер отвечает с задержкой, на остальные — сразу.
  FakeServer server(Map<String, dynamic> Function(String date) answer) =>
      FakeServer.routed(
        (method, url, body) {
          final date = url.queryParameters['date'] ?? '';
          return (200, jsonEncode(answer(date)));
        },
        delay: (url) => url.queryParameters['date'] == day(1)
            ? const Duration(milliseconds: 400)
            : null,
      );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      // Задержка ответа — на часах теста, их надо двигать.
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// Два шага назад подряд: за вчера ответ ещё не пришёл, а уже просим
  /// позавчера.
  Future<void> twoDaysBack(WidgetTester tester, Widget screen,
      FakeServer fake) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: screen,
      ));
      await settle(tester);
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.chevron_left));
      await tester.pump();
      await settle(tester);
    }, fake);
  }

  testWidgets('меню: под днём — меню этого дня', (tester) async {
    await twoDaysBack(
        tester,
        const MenuScreen(),
        server((date) => {
              'message': 'Success',
              'items': [
                {'category': 'Первые блюда', 'name': 'Суп $date', 'price': 900.0},
              ],
            }));
    expect(find.text('Суп ${day(2)}'), findsOneWidget);
    expect(find.text('Суп ${day(1)}'), findsNothing);
  });
}
