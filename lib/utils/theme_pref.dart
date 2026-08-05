import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Выбор темы: следовать системе, всегда светлая, всегда тёмная.
///
/// По умолчанию — как в телефоне. У большинства он и так переключается по
/// расписанию, а кому надо иначе — есть пункт в боковом меню.
class ThemePref {
  const ThemePref._();

  static const _key = 'themeMode';

  static ThemeMode fromName(String? name) {
    switch (name) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
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
  static ThemeMode read(SharedPreferences prefs) =>
      fromName(prefs.getString(_key));

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
