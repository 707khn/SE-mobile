import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_theme.dart';
import '../utils/app_version.dart';
import '../utils/biometric.dart';
import '../utils/colors.dart';
import '../utils/lang.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/theme_pref.dart';
import '../utils/variables.dart';
import 'about_screen.dart';
import 'change_password_screen.dart';
import 'pin_screen.dart';

/// «Настройки» — всё, что меняют под себя, на одном экране.
///
/// Раньше оформление, язык, пароль, код и «О программе» лежали в боковом
/// меню вперемешку с разделами приложения, и меню не помещалось на экран.
/// Теперь там один пункт, а здесь — группы: внешний вид, безопасность,
/// о приложении. Текущее значение видно справа, не открывая выбора.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _lang = Lang.ru;
  ThemeMode _themeMode = ThemeMode.system;
  String _fullName = '';
  String _job = '';

  /// null — на телефоне нет датчика или в нём ничего не заведено: тогда и
  /// строки нет.
  bool? _biometric;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final storage = SecureStorageHelper.instance;
    final fullName = await storage.getFullName();
    final job = await storage.getJob();
    final biometric = await Biometric.available()
        ? await storage.biometricEnabled()
        : null;
    if (!mounted) return;
    setState(() {
      _lang = Lang.code(prefs.getString(AppValues.LANG));
      _themeMode = ThemePref.read(prefs);
      _fullName = fullName ?? '';
      _job = job ?? '';
      _biometric = biometric;
    });
  }

  static String _langName(String code) =>
      Lang.isKazakh(code) ? 'Қазақша' : 'Русский';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('drawer_settings'.tr)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _section('settings_appearance'.tr),
          _tile(
            icon: ThemePref.icon(_themeMode),
            label: 'theme'.tr,
            value: ThemePref.label(_themeMode),
            onTap: _pickTheme,
          ),
          _tile(
            icon: Icons.translate,
            label: 'language'.tr,
            value: _langName(_lang),
            onTap: _pickLanguage,
          ),
          _section('settings_security'.tr),
          _tile(
            icon: Icons.lock_outline,
            label: 'password_change_title'.tr,
            onTap: () => Get.to(() => ChangePasswordScreen(
                  fullName: _fullName,
                  job: _job,
                  currentPassword: '',
                  mandatory: false,
                )),
          ),
          _tile(
            icon: Icons.pin_outlined,
            label: 'pin_change_title'.tr,
            onTap: () => Get.to(() => const PinScreen(mode: PinMode.change)),
          ),
          if (_biometric != null)
            SwitchListTile(
              secondary: Icon(Icons.fingerprint, color: context.mutedColor),
              title: Text('settings_biometric'.tr,
                  style: const TextStyle(fontSize: 15)),
              subtitle: Text('settings_biometric_hint'.tr,
                  style: TextStyle(fontSize: 12, color: context.mutedColor)),
              value: _biometric!,
              onChanged: _setBiometric,
            ),
          _section('settings_app'.tr),
          _tile(
            icon: Icons.info_outline,
            label: 'about_title'.tr,
            value: appVersionLabel(),
            onTap: () => Get.to(() => const AboutScreen()),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: AppColors.mainColor,
        ),
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    String? value,
  }) {
    return ListTile(
      leading: Icon(icon, color: context.mutedColor),
      title: Text(label, style: const TextStyle(fontSize: 15)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            Text(value,
                style: TextStyle(fontSize: 13, color: context.mutedColor)),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, color: context.mutedColor),
        ],
      ),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
    );
  }

  /// Включаем, только если палец подошёл прямо сейчас: иначе при следующем
  /// входе человек упрётся в окно, которое его не узнаёт.
  Future<void> _setBiometric(bool on) async {
    HapticFeedback.selectionClick();
    if (on && !await Biometric.authenticate()) return;
    await SecureStorageHelper.instance.setBiometricEnabled(on);
    if (mounted) setState(() => _biometric = on);
  }

  /// Выбор из короткого списка — нижним листом: до него дотягивается
  /// большой палец.
  Future<T?> _choose<T>({
    required String title,
    required List<T> options,
    required T current,
    required String Function(T) label,
    IconData Function(T)? icon,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
            for (final option in options)
              ListTile(
                leading: icon == null ? null : Icon(icon(option), size: 21),
                title: Text(label(option),
                    style: const TextStyle(fontSize: 14)),
                trailing: option == current
                    ? const Icon(Icons.check, color: AppColors.mainColor)
                    : null,
                onTap: () => Navigator.pop(ctx, option),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTheme() async {
    final chosen = await _choose<ThemeMode>(
      title: 'theme'.tr,
      options: ThemeMode.values,
      current: _themeMode,
      label: ThemePref.label,
      icon: ThemePref.icon,
    );
    if (chosen == null || chosen == _themeMode) return;
    await ThemePref.write(chosen);
    if (mounted) setState(() => _themeMode = chosen);
  }

  Future<void> _pickLanguage() async {
    final chosen = await _choose<String>(
      title: 'language'.tr,
      options: const [Lang.ru, Lang.kk],
      current: _lang,
      label: _langName,
    );
    if (chosen == null || chosen == _lang) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppValues.LANG, chosen);
    Get.updateLocale(Locale(chosen));
    if (mounted) setState(() => _lang = chosen);
  }
}
