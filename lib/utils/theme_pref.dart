import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Выбор темы: следовать системе, всегда светлая, всегда тёмная.
///
/// Пока человек не выбрал сам, на телефоне и компьютере — как в системе: у
/// большинства телефон и так переключается по расписанию. В браузере —
/// светлая: веб-версию решено открывать светлой, какая бы тема ни стояла в
/// системе. Выбор в «Настройках» хранится и перекрывает умолчание везде, в
/// браузере тоже.
class ThemePref {
  const ThemePref._();

  static const _key = 'themeMode';

  /// Тема, пока человек не выбрал сам. `web` — для проверок: в них
  /// приложение не в браузере, а проверить нужно и браузерное умолчание.
  static ThemeMode defaultMode({bool web = kIsWeb}) =>
      web ? ThemeMode.light : ThemeMode.system;

  /// «Как в системе» узнаётся по своему слову, а не уходит в умолчание: в
  /// браузере умолчание — светлая, и сам выбравший системную тему иначе
  /// получил бы светлую.
  static ThemeMode fromName(String? name, {bool web = kIsWeb}) {
    switch (name) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return defaultMode(web: web);
    }
  }

  static String toName(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  /// Читается синхронно при сборке приложения, поэтому SharedPreferences
  /// должны быть уже подняты — main() делает это до runApp.
  static ThemeMode read(SharedPreferences prefs, {bool web = kIsWeb}) =>
      fromName(prefs.getString(_key), web: web);

  static Future<void> write(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, toName(mode));
    Get.changeThemeMode(mode);
  }

  /// Название для меню: «Как в системе» / «Светлая» / «Тёмная».
  static String label(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'theme_light'.tr;
      case ThemeMode.dark:
        return 'theme_dark'.tr;
      case ThemeMode.system:
        return 'theme_system'.tr;
    }
  }

  static IconData icon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return Icons.light_mode_outlined;
      case ThemeMode.dark:
        return Icons.dark_mode_outlined;
      case ThemeMode.system:
        return Icons.brightness_auto_outlined;
    }
  }
}
