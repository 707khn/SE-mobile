import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/pin_screen.dart';
import 'package:se_mobile/screens/settings_screen.dart';
import 'package:se_mobile/utils/biometric.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';

/// Датчик понарошку: отвечает так, как скажет тест, и считает вызовы.
class _FakeBiometric implements Biometric {
  bool present = true;
  bool accepts = true;
  int asked = 0;

  @override
  Future<bool> available() async => present;

  @override
  Future<bool> authenticate(String reason) async {
    asked++;
    return accepts;
  }
}

/// Вход по отпечатку: только если включили сами, и код при этом остаётся.
void main() {
  late _FakeBiometric sensor;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    sensor = _FakeBiometric();
    Biometric.instance = sensor;
  });

  Future<void> settle(WidgetTester tester) async {
    // Хранилище и датчик отвечают не сразу — даём им отработать.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  /// Замок поверх обычного экрана — как после пяти минут в фоне.
  Future<void> relock(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 780) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: const Scaffold(body: Text('под замком')),
    ));
    Get.to(() => const PinScreen(mode: PinMode.relock),
        fullscreenDialog: true);
    await tester.pumpAndSettle();
    await settle(tester);
    await tester.pumpAndSettle();
  }

  Future<String?> stored(WidgetTester tester, String key) => tester
      .runAsync(() => const FlutterSecureStorage().read(key: key))
      .then((v) => v);

  testWidgets('включён — окно датчика сразу, узнал палец — замок снят',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues(
        {'pin': '1357', 'biometric': 'true', 'pinFails': '2'});
    await relock(tester);

    expect(sensor.asked, 1);
    expect(find.byType(PinScreen), findsNothing);
    expect(find.text('под замком'), findsOneWidget);
    expect(await stored(tester, 'pinFails'), isNull);
  });

  testWidgets('палец не узнал — остаётся код и кнопка с отпечатком',
      (tester) async {
    sensor.accepts = false;
    FlutterSecureStorage.setMockInitialValues(
        {'pin': '1357', 'biometric': 'true', 'pinFails': '2'});
    await relock(tester);

    expect(find.byType(PinScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('biometric')), findsOneWidget);
    // Неудачи датчика считает сам телефон, к неверным кодам они не идут.
    expect(await stored(tester, 'pinFails'), '2');

    await tester.tap(find.byKey(const ValueKey('biometric')));
    await settle(tester);
    expect(sensor.asked, 2);
  });

  testWidgets('не включали — датчик не трогаем', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'pin': '1357'});
    await relock(tester);

    expect(sensor.asked, 0);
    expect(find.byKey(const ValueKey('biometric')), findsNothing);
  });

  testWidgets('отпечаток стёрли из телефона — кнопки нет', (tester) async {
    sensor.present = false;
    FlutterSecureStorage.setMockInitialValues(
        {'pin': '1357', 'biometric': 'true'});
    await relock(tester);

    expect(sensor.asked, 0);
    expect(find.byKey(const ValueKey('biometric')), findsNothing);
  });

  group('настройки', () {
    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: const SettingsScreen(),
      ));
      await settle(tester);
    }

    testWidgets('без датчика строки нет', (tester) async {
      sensor.present = false;
      FlutterSecureStorage.setMockInitialValues({});
      await open(tester);
      expect(find.text('Вход по отпечатку пальца'), findsNothing);
    });

    testWidgets('включают, только приложив палец', (tester) async {
      sensor.accepts = false;
      FlutterSecureStorage.setMockInitialValues({});
      await open(tester);

      await tester.tap(find.text('Вход по отпечатку пальца'));
      await settle(tester);
      expect(sensor.asked, 1);
      expect(await tester.runAsync(SecureStorageHelper.instance.biometricEnabled),
          isFalse);

      sensor.accepts = true;
      await tester.tap(find.text('Вход по отпечатку пальца'));
      await settle(tester);
      expect(await tester.runAsync(SecureStorageHelper.instance.biometricEnabled),
          isTrue);

      // Выключают без пальца.
      await tester.tap(find.text('Вход по отпечатку пальца'));
      await settle(tester);
      expect(sensor.asked, 2);
      expect(await tester.runAsync(SecureStorageHelper.instance.biometricEnabled),
          isFalse);
    });
  });
}
