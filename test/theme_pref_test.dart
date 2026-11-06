import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/theme_pref.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Тема по умолчанию: в браузере — светлая, на телефоне и компьютере — как в
/// системе. Выбор, сделанный человеком в «Настройках», уже лежит у людей в
/// хранилище и должен пережить смену умолчания — в том числе «Как в
/// системе», которое раньше не отличалось от пустой настройки.
void main() {
  Future<SharedPreferences> stored(String? name) async {
    SharedPreferences.setMockInitialValues(
        {if (name != null) 'themeMode': name});
    return SharedPreferences.getInstance();
  }

  test('браузер: ничего не выбрано — светлая', () async {
    final prefs = await stored(null);
    expect(ThemePref.read(prefs, web: true), ThemeMode.light);
    expect(ThemePref.defaultMode(web: true), ThemeMode.light);
  });

  test('телефон и компьютер: ничего не выбрано — как в системе', () async {
    final prefs = await stored(null);
    expect(ThemePref.read(prefs, web: false), ThemeMode.system);
    expect(ThemePref.defaultMode(web: false), ThemeMode.system);
  });

  test('проверки идут не в браузере — умолчание телефонное', () {
    expect(ThemePref.defaultMode(), ThemeMode.system);
  });

  test('свой выбор сохраняется и в браузере, и на телефоне', () async {
    for (final web in [true, false]) {
      for (final mode in ThemeMode.values) {
        final prefs = await stored(ThemePref.toName(mode));
        expect(ThemePref.read(prefs, web: web), mode,
            reason: '${web ? 'браузер' : 'телефон'}: ${mode.name}');
      }
    }
  });

  test('непонятная запись — как будто ничего не выбрано', () async {
    final prefs = await stored('какая-то ерунда');
    expect(ThemePref.read(prefs, web: true), ThemeMode.light);
    expect(ThemePref.read(prefs, web: false), ThemeMode.system);
  });
}
