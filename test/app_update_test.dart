import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/utils/app_update.dart';
import 'package:se_mobile/utils/app_version.dart';

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
    // Номер передаёт сборка (--dart-define=APP_BUILD); без него — 0.
    expect(AppUpdate.currentBuild, greaterThanOrEqualTo(0));
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
}
