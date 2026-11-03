import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/functions/export_file.dart';
import 'package:se_mobile/functions/export_share.dart';
import 'package:se_mobile/screens/home_shell.dart';
import 'package:se_mobile/screens/it_request_form_screen.dart';
import 'package:se_mobile/screens/pin_screen.dart';
import 'package:se_mobile/utils/app_update.dart';
import 'package:se_mobile/utils/biometric.dart';
import 'package:se_mobile/utils/desktop.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/open_external.dart';
import 'package:se_mobile/utils/secure_storage_helper.dart';
import 'package:se_mobile/utils/shell_tab.dart';
import 'package:se_mobile/widgets/app_drawer.dart';
import 'package:se_mobile/widgets/desktop_layout.dart';

import 'support/fake_server.dart';

/// Версия для компьютера: то же приложение, но без того, чего у компьютера
/// нет, — камеры, отпечатка, «Поделиться».
void main() {
  setUp(() => debugDesktopOverride = true);
  tearDown(() => debugDesktopOverride = false);

  group('пути Windows', () {
    test('имя файла — и через «\\», и через «/»', () {
      expect(baseName(r'C:\Users\ivanov\Downloads\SE-mobile\a_2026.xlsx'),
          'a_2026.xlsx');
      expect(baseName('/home/ivanov/Загрузки/SE-mobile/a.csv'), 'a.csv');
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

  group('обновление', () {
    String answer(int build) => jsonEncode({
          'message': 'Success',
          'app': {
            'available': true,
            'version': '9.0.0',
            'build': build,
            'url': 'https://x/app/se-mobile-9.0.0+$build.apk',
            'size': 1,
          },
          'windows': {
            'available': true,
            'version': '9.0.1',
            'build': build + 1,
            'url': 'https://x/app/SemEng-windows-9.0.1+${build + 1}.zip',
            'size': 1,
          },
        });

    test('компьютеру предлагают архив, а не apk', () async {
      final server = FakeServer.routed(
          (_, __, ___) => (200, answer(AppUpdate.currentBuild + 1)));
      final update =
          await HttpOverrides.runWithHttpOverrides(AppUpdate.check, server);
      expect(update!.url, endsWith('.zip'));
      expect(update.version, '9.0.1');
    });

    test('телефону — по-прежнему apk', () async {
      debugDesktopOverride = false;
      final server = FakeServer.routed(
          (_, __, ___) => (200, answer(AppUpdate.currentBuild + 1)));
      final update =
          await HttpOverrides.runWithHttpOverrides(AppUpdate.check, server);
      expect(update!.url, endsWith('.apk'));
    });

    test('архива на сервере нет — молчим', () async {
      final server = FakeServer.routed((_, __, ___) => (
            200,
            jsonEncode({
              'message': 'Success',
              'app': {'available': true, 'build': 9999, 'url': 'u'},
              'windows': {'available': false, 'reason': 'нет'},
            })
          ));
      expect(
          await HttpOverrides.runWithHttpOverrides(AppUpdate.check, server),
          isNull);
    });
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

  testWidgets('номер телефона копируется, а не набирается', (tester) async {
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
    await openExternal(context, 'tel:+77222123456');
    await tester.pump();

    expect(copied, '+77222123456');
    expect(find.text('Номер скопирован: +77222123456'), findsOneWidget);
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

  testWidgets('Esc — назад, а из поля ввода сначала выводит', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(GetMaterialApp(
      builder: (context, child) =>
          DesktopKeys(navigator: () => Get.key.currentState, child: child!),
      home: const Scaffold(body: Text('главная')),
    ));
    Get.to(() => const Scaffold(body: TextField(key: Key('field'))));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('field')));
    await tester.enterText(find.byKey(const Key('field')), 'Не печатает');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Не печатает'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('главная'), findsOneWidget);
    expect(find.byKey(const Key('field')), findsNothing);

    // Окно поверх страницы закрывается первым.
    Get.to(() => const Scaffold(body: Text('страница')));
    await tester.pumpAndSettle();
    Get.dialog(const AlertDialog(content: Text('окно')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('окно'), findsNothing);
    expect(find.text('страница'), findsOneWidget);
  });

  testWidgets('вкладки на компьютере — слева, на узком окне — внизу',
      (tester) async {
    await pump(tester, const HomeShell(fullName: 'Иванов Иван', job: 'Инженер'),
        size: const Size(1400, 900));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await pump(tester, const HomeShell(fullName: 'Иванов Иван', job: 'Инженер'),
        size: const Size(500, 900));
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
  });

  Future<void> pumpLayout(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(
        {'fullName': 'Иванов Иван', 'job': 'Инженер'});
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      builder: (context, child) => DesktopLayout(child: child!),
      home: const HomeShell(fullName: 'Иванов Иван', job: 'Инженер'),
    ));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('на мониторе разделы — панелью слева, без «≡» и полоски вкладок',
      (tester) async {
    await pumpLayout(tester, const Size(1920, 1000));
    expect(find.byWidgetPredicate((w) => w is AppDrawer && w.permanent),
        findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byIcon(Icons.menu), findsNothing);
    // Раздел — справа от панели и не шире положенного.
    final scaffold = tester.getRect(find.byType(Scaffold).first);
    expect(scaffold.left, greaterThan(kDesktopSidebarWidth));
    expect(scaffold.width, kDesktopWideContentWidth);

    await tester.tap(find.text('Отпуск').first);
    await tester.pump();
    expect(ShellTab.selected.value, 3);
    ShellTab.open(0);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('узкое окно — без панели, с полоской вкладок; экраны не теряются',
      (tester) async {
    await pumpLayout(tester, const Size(1920, 1000));
    Get.to(() => const Scaffold(body: Text('Открытый экран')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    expect(find.text('Открытый экран'), findsOneWidget);

    tester.view.physicalSize = const Size(900, 1000);
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is AppDrawer && w.permanent),
        findsNothing);
    // Навигатор переехал, а не создан заново: открытый экран на месте.
    expect(find.text('Открытый экран'), findsOneWidget);
    Get.back();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(NavigationRail), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
