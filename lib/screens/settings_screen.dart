import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_theme.dart';
import '../utils/app_version.dart';
import '../utils/biometric.dart';
import '../utils/colors.dart';
import '../utils/lang.dart';
import '../utils/own_password.dart';
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

  /// Есть ли на телефоне датчик с заведённым отпечатком. Нет — строки
  /// «Вход по отпечатку» не показываем вовсе, чтобы не обещать лишнего.
  bool _biometricAvailable = false;
  bool _biometricOn = false;

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
    final biometricAvailable = await Biometric.instance.available();
    final biometricOn = await storage.biometricEnabled();
    if (!mounted) return;
    setState(() {
      _lang = Lang.code(prefs.getString(AppValues.LANG));
      _themeMode = ThemePref.read(prefs);
      _fullName = fullName ?? '';
      _job = job ?? '';
      _biometricAvailable = biometricAvailable;
      _biometricOn = biometricOn;
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
          // Вошедший с телефона или из браузера по одноразовому коду своего
          // пароля не имеет: пароль ему нужен для входа с компьютера.
          ValueListenableBuilder<bool>(
            valueListenable: OwnPassword.has,
            builder: (context, has, _) => _tile(
              icon: Icons.lock_outline,
              label: has
                  ? 'password_change_title'.tr
                  : 'password_set_title'.tr,
              onTap: () => Get.to(() => ChangePasswordScreen(
                    fullName: _fullName,
                    job: _job,
                    currentPassword: '',
                    mandatory: false,
                    hasPassword: has,
                  )),
            ),
          ),
          _tile(
            icon: Icons.pin_outlined,
            label: 'pin_change_title'.tr,
            onTap: () => Get.to(() => const PinScreen(mode: PinMode.change)),
          ),
          if (_biometricAvailable)
            SwitchListTile(
              secondary: Icon(Icons.fingerprint, color: context.mutedColor),
              title: Text('biometric_setting'.tr,
                  style: const TextStyle(fontSize: 15)),
              subtitle: Text('biometric_setting_hint'.tr,
                  style: TextStyle(fontSize: 12.5, color: context.mutedColor)),
              value: _biometricOn,
              onChanged: _toggleBiometric,
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

  /// Включить можно, только приложив палец: так человек сразу видит, что
  /// датчик его узнаёт, а чужой, взявший открытый телефон, не включит вход
  /// своим пальцем. Выключают без вопросов — код остаётся.
  Future<void> _toggleBiometric(bool on) async {
    HapticFeedback.selectionClick();
    if (on && !await Biometric.instance.authenticate(biometricReason())) {
      return;
    }
    await SecureStorageHelper.instance.setBiometricEnabled(on);
    if (mounted) setState(() => _biometricOn = on);
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
