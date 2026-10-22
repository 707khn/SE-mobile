import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/utils/app_update.dart';
import 'package:se_mobile/utils/app_version.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/widgets/update_gate.dart';

/// Приложение раздаётся руками, и пока сборку негде было взять, обновлялись
/// единицы. Теперь оно предлагает новую само — и не должно ни надоедать, ни
/// молчать, когда сказать есть о чём.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const update = AppUpdate(
    version: '1.9.1',
    build: 14,
    url: 'https://api.se-btrz.com/app/se-mobile-1.9.1+14.apk',
    sizeBytes: 48234496,
  );

  test('подпись — версия и номер сборки', () {
    expect(update.label, '1.9.1 (14)');
  });

  test('размер называется заранее', () {
    // Скачивают по заводскому каналу — человек вправе знать, на что идёт.
    expect(update.sizeLabel, '46 МБ');
    expect(
        const AppUpdate(version: '1', build: 1, url: 'u', sizeBytes: 3355443)
            .sizeLabel,
        '3.2 МБ');
    expect(
        const AppUpdate(version: '1', build: 1, url: 'u', sizeBytes: 0)
            .sizeLabel,
        '');
  });

  test('номер установленной сборки — число', () {
    expect(AppUpdate.currentBuild, int.parse(kAppBuild));
    expect(AppUpdate.currentBuild, greaterThan(0));
  });

  test('«позже» откладывает эту сборку, а не обновления вообще', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await update.isDismissed(), isFalse);

    await update.dismiss();
    expect(await update.isDismissed(), isTrue);

    // Следующая сборка спросит снова — иначе один отказ означал бы «больше
    // никогда», а напомнить как раз и нужно.
    const next = AppUpdate(
        version: '1.9.2', build: 15, url: 'u', sizeBytes: 1);
    expect(await next.isDismissed(), isFalse);
  });

  group('минимальная сборка', () {
    final current = AppUpdate.currentBuild;

    test('ниже минимальной — дальше не пускаем', () {
      expect(UpdateStatus(minBuild: current + 1).required, isTrue);
    });

    test('сама минимальная и выше — работаем', () {
      expect(UpdateStatus(minBuild: current).required, isFalse);
      expect(const UpdateStatus(minBuild: 0).required, isFalse);
    });

    test('последний ответ сервера переживает перезапуск без связи', () async {
      // Иначе устаревшую сборку можно было бы пройти, выключив сеть.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'updateMinBuild': current + 1,
        'updateRequiredApp': jsonEncode({
          'available': true,
          'version': '9.9.9',
          'build': current + 1,
          'url': 'https://api.se-btrz.com/app/se-mobile-9.9.9+${current + 1}.apk',
          'size': 1024 * 1024 * 40,
        }),
      });
      final status =
          UpdateStatus.remembered(await SharedPreferences.getInstance());
      expect(status.required, isTrue);
      expect(status.latest?.build, current + 1);
    });

    test('испорченная запись не запирает приложение', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'updateRequiredApp': '{не json',
      });
      final status =
          UpdateStatus.remembered(await SharedPreferences.getInstance());
      expect(status.required, isFalse);
    });
  });

  group('экран «Нужно обновить»', () {
    Future<void> pump(WidgetTester tester, Map<String, Object> saved) async {
      SharedPreferences.setMockInitialValues(saved);
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        builder: (context, child) =>
            UpdateGate(prefs: prefs, child: child ?? const SizedBox()),
        home: const Scaffold(body: Text('главный экран')),
      ));
      await tester.pump();
    }

    testWidgets('устаревшая сборка видит экран и кнопку скачать',
        (tester) async {
      final next = AppUpdate.currentBuild + 1;
      await pump(tester, {
        'updateMinBuild': next,
        'updateRequiredApp': jsonEncode({
          'available': true,
          'version': '9.9.9',
          'build': next,
          'url': 'https://api.se-btrz.com/app/se-mobile-9.9.9+$next.apk',
          'size': 0,
        }),
      });
      expect(find.text('Нужно обновить приложение'), findsOneWidget);
      expect(find.textContaining('9.9.9 ($next)'), findsOneWidget);
      expect(find.text('главный экран'), findsNothing);
    });

    testWidgets('без файла на сервере — честно говорим, к кому идти',
        (tester) async {
      await pump(tester, {'updateMinBuild': AppUpdate.currentBuild + 1});
      expect(find.text('Нужно обновить приложение'), findsOneWidget);
      expect(find.textContaining('администратору'), findsOneWidget);
    });

    testWidgets('свежая сборка экрана не видит', (tester) async {
      await pump(tester, {'updateMinBuild': AppUpdate.currentBuild});
      expect(find.text('главный экран'), findsOneWidget);
      expect(find.text('Нужно обновить приложение'), findsNothing);
    });
  });
}
