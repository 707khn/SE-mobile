import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/utils/offline_cache.dart';

/// Копии на телефоне не копятся без конца: меню сохраняется на каждый
/// день, а shared_preferences переписывает свой файл целиком при каждом
/// сохранении.
void main() {
  test('из копий меню остаются последние дни, остальное не трогается',
      () async {
    final values = <String, Object>{
      for (var day = 1; day <= 20; day++)
        'offline_menu_2026-09-${day.toString().padLeft(2, '0')}': '{}',
      'offline_news': '{}',
      'offline_payslip_OWN0001_2026_07': '{}',
      'theme': 'dark',
    };
    SharedPreferences.setMockInitialValues(values);

    await OfflineCache.trim('menu_', keep: 14);

    final prefs = await SharedPreferences.getInstance();
    final menus = prefs.getKeys().where((k) => k.startsWith('offline_menu_'));
    expect(menus.length, 14);
    expect(prefs.containsKey('offline_menu_2026-09-20'), isTrue);
    expect(prefs.containsKey('offline_menu_2026-09-07'), isTrue);
    expect(prefs.containsKey('offline_menu_2026-09-06'), isFalse);
    expect(prefs.containsKey('offline_news'), isTrue);
    expect(prefs.containsKey('offline_payslip_OWN0001_2026_07'), isTrue);
    expect(prefs.getString('theme'), 'dark');
  });

  test('меньше предела — ничего не удаляется', () async {
    SharedPreferences.setMockInitialValues({
      'offline_menu_2026-09-01': '{}',
      'offline_menu_2026-09-02': '{}',
    });
    await OfflineCache.trim('menu_', keep: 14);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().length, 2);
  });
}
