import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/utils/offline_cache.dart';

/// Расчётные листки на телефоне лежат в защищённом хранилище, а не в
/// открытом файле shared_preferences.
void main() {
  const secure = FlutterSecureStorage();

  test('личное сохраняется в защищённое, а не в открытый файл', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});

    await OfflineCache.save('payslip_OWN0001_2026_09', {'net_pay': 100},
        private: true);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('offline_payslip_OWN0001_2026_09'), isFalse);
    expect(await secure.read(key: 'offline_payslip_OWN0001_2026_09'),
        contains('net_pay'));

    final back =
        await OfflineCache.read('payslip_OWN0001_2026_09', private: true);
    expect(back?['net_pay'], 100);
    expect(cachedAt(back), isNotNull);
  });

  test('листок от прежней сборки переносится из открытого файла', () async {
    SharedPreferences.setMockInitialValues(
        {'offline_payslip_OWN0001_2026_08': '{"net_pay": 7}'});
    FlutterSecureStorage.setMockInitialValues({});

    final back =
        await OfflineCache.read('payslip_OWN0001_2026_08', private: true);
    expect(back?['net_pay'], 7);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('offline_payslip_OWN0001_2026_08'), isFalse);
    expect(
        await secure.read(key: 'offline_payslip_OWN0001_2026_08'), isNotNull);
  });

  test('из листков остаются последние месяцы, пропуск не трогается', () async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({
      for (var m = 1; m <= 12; m++)
        'offline_payslip_OWN0001_2025_${m.toString().padLeft(2, '0')}': '{}',
      'offline_payslip_OWN0001_2026_01': '{}',
      'offline_payslip_OWN0001_2026_02': '{}',
      'token': 'secret',
    });

    await OfflineCache.trim('payslip_OWN0001_', keep: 13, private: true);

    final all = await secure.readAll();
    expect(all.keys.where((k) => k.startsWith('offline_payslip_')).length, 13);
    expect(all.containsKey('offline_payslip_OWN0001_2025_01'), isFalse);
    expect(all.containsKey('offline_payslip_OWN0001_2026_02'), isTrue);
    expect(all['token'], 'secret');
  });

  test('выход стирает сохранённое в обоих хранилищах', () async {
    SharedPreferences.setMockInitialValues(
        {'offline_menu_2026-09-01': '{}', 'theme': 'dark'});
    FlutterSecureStorage.setMockInitialValues(
        {'offline_payslip_OWN0001_2026_09': '{}', 'token': 'secret'});

    await OfflineCache.clear();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('offline_menu_2026-09-01'), isFalse);
    expect(prefs.getString('theme'), 'dark');
    final all = await secure.readAll();
    expect(all.containsKey('offline_payslip_OWN0001_2026_09'), isFalse);
    expect(all['token'], 'secret');
  });
}
