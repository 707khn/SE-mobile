import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/menu_edit_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/offline_cache.dart';
import 'package:se_mobile/widgets/load_error_view.dart';

import 'support/fake_server.dart';

/// Редактор меню не правит меню, которого не получил.
///
/// Сохранение заменяет день целиком. Когда меню не загружалось, редактор
/// показывал пустой день — технолог добавлял блюдо, сохранял, и от меню дня
/// оставалось одно это блюдо. А при сохранённой на телефоне копии он правил
/// её и затирал всё, что поменяли на сервере после неё.
void main() {
  final day = DateTime(2031, 5, 6);
  const key = 'menu_2031-05-06';

  Future<void> open(WidgetTester tester, FakeServer server,
      {Map<String, dynamic>? saved}) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    if (saved != null) {
      await tester.runAsync(() => OfflineCache.save(key, saved));
    }
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: MenuEditScreen(initialDate: day),
      ));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future.delayed(const Duration(milliseconds: 60)));
        await tester.pump();
      }
    }, server);
  }

  Map<String, dynamic> menu(String dish) => {
        'message': 'Success',
        'items': [
          {'category': 'Первые блюда', 'name': dish, 'price': 900.0},
        ],
      };

  testWidgets('не загрузилось — ошибка, а не пустой день', (tester) async {
    await open(tester, FakeServer(502, 'Bad Gateway'));
    expect(find.byType(LoadErrorView), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('не загрузилось — сохранённая копия не правится',
      (tester) async {
    await open(tester, FakeServer(502, 'Bad Gateway'),
        saved: menu('Борщ из копии'));
    expect(find.byType(LoadErrorView), findsOneWidget);
    expect(find.text('Борщ из копии'), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('загрузилось — меню дня и кнопка добавить', (tester) async {
    await open(
        tester,
        FakeServer(200, jsonEncode(menu('Борщ с сервера')),
            contentType: 'application/json; charset=utf-8'));
    expect(find.text('Борщ с сервера'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byType(LoadErrorView), findsNothing);
  });

  testWidgets('пустой день с сервера — можно добавлять', (tester) async {
    await open(
        tester,
        FakeServer(200, jsonEncode({'message': 'Success', 'items': []}),
            contentType: 'application/json; charset=utf-8'));
    expect(find.byType(LoadErrorView), findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
