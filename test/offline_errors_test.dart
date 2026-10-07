import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/directory_screen.dart';
import 'package:se_mobile/screens/news_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/widgets/load_error_view.dart';

/// Справочник и новости без связи и без сохранённого: экран называет
/// причину, а не пишет одно общее «не удалось загрузить». Сервер в
/// тестовой среде недоступен всегда.
void main() {
  Future<void> open(WidgetTester tester, Widget screen) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: screen,
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
  }

  testWidgets('справочник', (tester) async {
    await open(tester, const DirectoryScreen());
    expect(find.byType(LoadErrorView), findsOneWidget);
  });

  testWidgets('новости', (tester) async {
    await open(tester, const NewsScreen());
    expect(find.byType(LoadErrorView), findsOneWidget);
  });
}
