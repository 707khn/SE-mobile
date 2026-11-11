import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/pin_screen.dart';
import 'package:se_mobile/utils/app_lock.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/offline_cache.dart';

/// Веб-версия и программа для компьютера: расчётный лист не остаётся в
/// браузере и не висит на экране общего компьютера.
void main() {
  const secure = FlutterSecureStorage();

  group('в браузере листок не сохраняется', () {
    setUp(() => OfflineCache.debugWebOverride = true);
    tearDown(() => OfflineCache.debugWebOverride = null);

    test('новый листок не ложится ни в одно хранилище', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});

      await OfflineCache.save('payslip_OWN0001_2026_09', {'net_pay': 100},
          private: true);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('offline_payslip_OWN0001_2026_09'), isFalse);
      expect(await secure.read(key: 'offline_payslip_OWN0001_2026_09'),
          isNull);
      expect(await OfflineCache.read('payslip_OWN0001_2026_09', private: true),
          isNull);
    });

    test('листок от прежней сборки стирается при первом же чтении', () async {
      SharedPreferences.setMockInitialValues(
          {'offline_payslip_OWN0001_2026_08': '{"net_pay": 7}'});
      FlutterSecureStorage.setMockInitialValues(
          {'offline_payslip_OWN0001_2026_08': '{"net_pay": 7}', 'token': 't'});

      expect(await OfflineCache.read('payslip_OWN0001_2026_08', private: true),
          isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('offline_payslip_OWN0001_2026_08'), isFalse);
      expect(await secure.read(key: 'offline_payslip_OWN0001_2026_08'),
          isNull);
      expect(await secure.read(key: 'token'), 't');
    });

    test('общее (меню) сохраняется как раньше', () async {
      SharedPreferences.setMockInitialValues({});
      await OfflineCache.save('menu_2026-11-11', {'items': []});
      expect(await OfflineCache.read('menu_2026-11-11'), isNotNull);
    });
  });

  group('простой на компьютере закрывает окно кодом', () {
    setUp(() {
      AppLock.debugWatchIdleOverride = true;
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() {
      AppLock.instance.stop();
      AppLock.debugWatchIdleOverride = null;
    });

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const Scaffold(body: Text('Расчётный лист')),
      ));
      AppLock.instance.start();
    }

    Future<void> idle(WidgetTester tester, Duration after) async {
      await tester.runAsync(() => AppLock.instance
          .checkIdle(now: DateTime.now().add(after))
          .timeout(const Duration(milliseconds: 300), onTimeout: () {}));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('через пять минут без мыши — экран кода', (tester) async {
      FlutterSecureStorage.setMockInitialValues({'pin': '1357'});
      await open(tester);
      await idle(tester, const Duration(minutes: 6));
      expect(find.byType(PinScreen), findsOneWidget);
      AppLock.instance.stop();
    });

    testWidgets('через минуту — ещё нет', (tester) async {
      FlutterSecureStorage.setMockInitialValues({'pin': '1357'});
      await open(tester);
      await idle(tester, const Duration(minutes: 1));
      expect(find.byType(PinScreen), findsNothing);
      AppLock.instance.stop();
    });

    testWidgets('без кода закрывать нечем — не закрываем', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await open(tester);
      await idle(tester, const Duration(minutes: 6));
      expect(find.byType(PinScreen), findsNothing);
      AppLock.instance.stop();
    });
  });
}
