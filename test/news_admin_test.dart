import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/news_admin_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/widgets/load_error_view.dart';

import 'support/fake_server.dart';

/// Очередь объявлений у администратора.
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester, FakeServer server) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const NewsAdminScreen(),
      ));
      await settle(tester);
    }, server);
  }

  testWidgets('очередь не загрузилась — ошибка, а не «новостей нет»',
      (tester) async {
    await open(tester, FakeServer(502, 'Bad Gateway'));
    expect(find.byType(LoadErrorView), findsOneWidget);
    expect(find.text('news_empty'.tr), findsNothing);
  });

  testWidgets('объявление не ушло — набранный текст остаётся', (tester) async {
    // Очередь отдаётся, а публикация не проходит.
    final server = FakeServer.routed((method, url, body) => method == 'GET'
        ? (200, jsonEncode({'items': [], 'pending': 0}))
        : (502, 'Bad Gateway'));
    await open(tester, server);
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);
      // Без заголовка публиковать нельзя.
      final publish = find.widgetWithText(TextButton, 'publish'.tr);
      expect(tester.widget<TextButton>(publish).onPressed, isNull);
      await tester.enterText(find.byType(TextField).first, 'Собрание в пятницу');
      await tester.enterText(find.byType(TextField).last, 'В актовом зале.');
      await tester.pump();
      await tester.tap(publish);
      await settle(tester);
      expect(find.text('news_save_failed'.tr), findsOneWidget);
      await tester.tap(find.byType(FloatingActionButton));
      await settle(tester);
    }, server);
    expect(find.text('Собрание в пятницу'), findsOneWidget);
    expect(find.text('В актовом зале.'), findsOneWidget);
  });
}
