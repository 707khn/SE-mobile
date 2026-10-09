import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/menu_screen.dart';
import 'package:se_mobile/screens/payslip_screen.dart';
import 'package:se_mobile/screens/pin_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

/// Крупный шрифт на маленьком телефоне.
///
/// На складе и в столовой шрифт в телефоне часто увеличивают; приложение
/// пускает его до 1,3 (см. main.dart). На 320×568 при этом клавиатура кода
/// наезжала на кружки и уходила за край, строка выбора месяца в листке не
/// помещалась, а заглушка загрузки меню не рисовалась вовсе и писала ошибку
/// в журнал «О программе» при каждом открытии.
///
/// Шрифт — настоящий Roboto из Flutter, которым запущены проверки: тестовый
/// по умолчанию рисует каждую букву квадратом, и ширина текста выходит
/// ложной.
Future<void> _realFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final name in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    final file = File('$dir/$name');
    if (file.existsSync()) {
      roboto.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
  }
  await roboto.load();
}

void main() {
  setUpAll(_realFonts);

  final screens = <String, Widget Function()>{
    'создание кода': () => const PinScreen(mode: PinMode.create),
    'ввод кода': () => const PinScreen(mode: PinMode.unlock),
    'меню': () => const MenuScreen(),
    'листок': () => const PayslipPage(),
  };

  for (final lang in ['ru', 'kk']) {
    for (final entry in screens.entries) {
      testWidgets('${entry.key} ($lang): 320×568, шрифт 1,3', (tester) async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({'employeeId': 'TEST0001'});
        await tester.runAsync(Lang.initDates);
        tester.view.physicalSize = const Size(320, 568) * tester.view.devicePixelRatio;
        addTearDown(tester.view.resetPhysicalSize);

        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError =
            (d) => errors.add(d.exceptionAsString().split('\n').first);
        await tester.pumpWidget(GetMaterialApp(
          translations: LocaleString(),
          locale: Locale(lang),
          theme: ThemeData(fontFamily: 'Roboto'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: entry.value(),
        ));
        // Первый кадр — с заглушкой загрузки, дальше — ответ (здесь ошибка
        // связи: сервера в проверках нет).
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(
              () => Future.delayed(const Duration(milliseconds: 80)));
          await tester.pump(const Duration(milliseconds: 300));
        }
        FlutterError.onError = previous;
        expect(errors, isEmpty);
      });
    }
  }
}
