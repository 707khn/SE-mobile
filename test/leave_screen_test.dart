import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/leave_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/widgets/load_error_view.dart';
import 'package:se_mobile/widgets/offline_notice.dart';

/// Экран отпуска без связи. Сервер здесь недоступен всегда: тестовая
/// среда отвечает на любой запрос ошибкой.
///
/// Раньше в обоих случаях экран писал «данные об отпусках не найдены», и
/// человек без интернета думал, что у него пропал отпуск.
void main() {
  Future<void> open(WidgetTester tester) async {
    // Даты по-русски: в приложении их поднимает main().
    await tester.runAsync(Lang.initDates);
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: const LeavePage(),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
  }

  testWidgets('нет связи и нет сохранённого — причина, а не «не найдено»',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'employeeId': 'TEST0001'});
    await open(tester);

    expect(find.byType(LoadErrorView), findsOneWidget);
    expect(find.text('leave not found'.tr), findsNothing);
  });

  testWidgets('нет связи, но есть сохранённое — оно, с пометкой',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'offline_leaves_TEST0001': jsonEncode({
        'message': 'Success',
        'cached_at': DateTime(2026, 10, 1, 9, 30).toIso8601String(),
        'leaves': {
          'employee': 'Отпускова Тест Тестовна',
          'balances': [
            {
              'type': 'Ежегодный трудовой отпуск',
              'total_days': 24,
              'used_days': 10,
              'remaining_days': 14,
            }
          ],
          'history': [],
        },
      }),
    });
    FlutterSecureStorage.setMockInitialValues({'employeeId': 'TEST0001'});
    await open(tester);

    expect(find.byType(LoadErrorView), findsNothing);
    expect(find.text('Отпускова Тест Тестовна'), findsOneWidget);
    expect(find.byType(OfflineNotice), findsOneWidget);
  });
}
