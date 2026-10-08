import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/pin_screen.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';

/// Смена кода: старый код спрашивают под тем же счётчиком, что и при входе.
///
/// Раньше здесь ошибаться можно было без счёта, и по открытому телефону код
/// подбирался перебором — а его нередко ставят тот же, что на карте.
void main() {
  Future<void> open(WidgetTester tester, {Size size = const Size(360, 640)}) async {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: const PinScreen(mode: PinMode.change),
    ));
    await tester.pump();
  }

  Future<void> enter(WidgetTester tester, String code) async {
    for (final digit in code.split('')) {
      await tester.tap(find.text(digit));
      await tester.pump();
    }
    // Проверка кода идёт через защищённое хранилище — даём ей отработать.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<int> fails(WidgetTester tester) async =>
      (await tester.runAsync(SecureStorageHelper.instance.getPinFails))!;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({'pin': '1357'});
  });

  testWidgets('неверный старый код идёт в счёт', (tester) async {
    await open(tester);
    for (var i = 1; i <= 4; i++) {
      await enter(tester, '0000');
      expect(await fails(tester), i);
    }
    expect(find.textContaining('Осталось попыток: 1'), findsOneWidget);
  });

  testWidgets('верный старый код обнуляет счёт', (tester) async {
    FlutterSecureStorage.setMockInitialValues({'pin': '1357', 'pinFails': '3'});
    await open(tester);
    await enter(tester, '1357');
    expect(await fails(tester), 0);
  });
}
