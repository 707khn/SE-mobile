import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/functions/export_file.dart';
import 'package:se_mobile/functions/export_share.dart';
import 'package:se_mobile/screens/it_request_form_screen.dart';
import 'package:se_mobile/screens/pin_screen.dart';
import 'package:se_mobile/utils/biometric.dart';
import 'package:se_mobile/utils/desktop.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';

/// Версия для компьютера: то же приложение, но без того, чего у компьютера
/// нет, — камеры, отпечатка, «Поделиться».
void main() {
  setUp(() => debugDesktopOverride = true);
  tearDown(() => debugDesktopOverride = false);

  group('пути Windows', () {
    test('имя файла — и через «\\», и через «/»', () {
      expect(baseName(r'C:\Users\ivanov\Downloads\SemEng\a_2026.xlsx'),
          'a_2026.xlsx');
      expect(baseName('/home/ivanov/Загрузки/SemEng/a.csv'), 'a.csv');
      expect(baseName('a.csv'), 'a.csv');
    });

    test('выход уносит и расчётные листки, а чужое не трогает', () async {
      final dir = await Directory.systemTemp.createTemp('semeng_');
      addTearDown(() => dir.delete(recursive: true));
      final own = await saveExport(dir, 'Иванов', 'xlsx', [1]);
      final payslip = File('${dir.path}/Расчетный листок Июль 2026.xlsx')
        ..writeAsBytesSync([2]);
      final foreign = File('${dir.path}/Отпуск.xlsx')..writeAsBytesSync([3]);

      await clearExports(dir);

      expect(own.existsSync(), isFalse);
      expect(payslip.existsSync(), isFalse);
      expect(foreign.existsSync(), isTrue);
    });
  });

  test('отпечатка на компьютере нет', () async {
    expect(await Biometric.instance.available(), isFalse);
  });

  Future<void> pump(WidgetTester tester, Widget home,
      {Size size = const Size(800, 1600)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      builder: (context, child) => DesktopFrame(child: child!),
      home: home,
    ));
    await tester.pump();
  }

  testWidgets('заявка в ОИТиС: вместо камеры — файл', (tester) async {
    await pump(tester, const ItRequestFormScreen());
    expect(find.text('Снять'), findsNothing);
    expect(find.text('Из галереи'), findsNothing);
    expect(find.text('Выбрать файл'), findsOneWidget);
  });

  testWidgets('текст «отправить» уходит в буфер обмена', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    late BuildContext context;
    await pump(tester, Scaffold(body: Builder(builder: (c) {
      context = c;
      return const SizedBox.shrink();
    })));
    await shareText(context, 'Отпуск: 24 дня');
    await tester.pump();

    expect(copied, 'Отпуск: 24 дня');
    expect(find.text('Скопировано'), findsOneWidget);
  });

  testWidgets('на широком окне — колонка посередине', (tester) async {
    late double width;
    await pump(
        tester,
        Builder(builder: (context) {
          width = MediaQuery.of(context).size.width;
          return const Scaffold();
        }),
        size: const Size(1920, 1000));
    expect(width, kDesktopContentWidth);
    expect(tester.getSize(find.byType(Scaffold)).width, kDesktopContentWidth);
  });

  testWidgets('узкое окно — как есть', (tester) async {
    await pump(tester, const Scaffold(), size: const Size(500, 900));
    expect(tester.getSize(find.byType(Scaffold)).width, 500);
  });

  testWidgets('код набирается с клавиатуры', (tester) async {
    await pump(tester, const PinScreen(mode: PinMode.create));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad4);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.pump();
    // Четыре цифры «1345» — дальше просят повторить.
    expect(find.text('pin_repeat_hint'.tr), findsOneWidget);
    expect(await SecureStorageHelper.instance.hasPin(), isFalse);
  });
}
