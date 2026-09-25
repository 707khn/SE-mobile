import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/about_screen.dart';
import '../screens/admin_panel_screen.dart';
import '../screens/attendance_screen.dart';
import '../screens/change_password_screen.dart';
import '../screens/directory_screen.dart';
import '../screens/news_screen.dart';
import '../screens/pin_screen.dart';
import '../screens/main_screen_2.dart';
import '../screens/menu_screen.dart';
import '../utils/app_version.dart';
import '../utils/colors.dart';
import '../utils/shell_tab.dart';
import '../utils/dimensions.dart';
import '../utils/theme_pref.dart';
import '../utils/logout_helper.dart';
import '../utils/role_helper.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import 'icon_button_drawer.dart';
import '../utils/app_theme.dart';

/// The navigation drawer shared by every section.
///
/// Reads the signed-in user's profile itself, so screens that never receive a
/// name or job title (payslip, leave, canteen menu…) can use it as-is.
class AppDrawer extends StatefulWidget {
  const AppDrawer({Key? key, this.onNavigate, this.currentIndex}) : super(key: key);

  /// Supplied by the tabs inside the shell to switch tab directly. When null
  /// the drawer is on a pushed screen and rebuilds the shell instead.
  final ValueChanged<int>? onNavigate;

  /// Tab index of the screen showing this drawer, highlighted in the list.
  final int? currentIndex;

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  String _lang = "RU";
  ThemeMode _themeMode = ThemeMode.system;
  String _fullName = '';
  String _job = '';
  String? _login;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final storage = SecureStorageHelper.instance;
    final prefs = await SharedPreferences.getInstance();
    final fullName = await storage.getFullName();
    final job = await storage.getJob();
    final login = await storage.getLogin();
    if (!mounted) return;
    setState(() {
      _lang = prefs.getString(AppValues.LANG) ?? "RU";
      _themeMode = ThemePref.read(prefs);
      _fullName = fullName ?? '';
      _job = job ?? '';
      _login = login;
    });
  }

  bool get _isAdmin => isSystemAdmin(_job);

  /// ФИО is "Фамилия Имя Отчество", so the given name is the second word.
  String get _givenName {
    final parts = _fullName.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[1].isNotEmpty) return parts[1];
    return parts.isNotEmpty ? parts.first : _fullName;
  }

  /// Переход на вкладку — из самой вкладки или с открытого поверх экрана.
  ///
  /// Прежде со второго случая оболочка создавалась заново (`Get.offAll`).
  /// Вместе с ней заново создавались все пять вкладок, уходило пять запросов
  /// к серверу, а открытый расчётный лист, выбранный период и прокрутка
  /// пропадали: человек нажимал «Проходы» и заодно терял всё, что успел
  /// настроить.
  ///
  /// Теперь оболочка одна на сеанс. Меняем в ней вкладку и сворачиваем
  /// стопку экранов, открытых поверх неё.
  void _goToTab(int index) {
    ShellTab.open(index);
    if (widget.onNavigate == null) {
      Get.until((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                if (_isAdmin) ...[
                  _item(
                    icon: Icons.admin_panel_settings,
                    label: 'admin_panel'.tr,
                    onTap: () => Get.to(() => const AdminPanelScreen()),
                  ),
                  // Pushed as a route: the admin has no tab bar.
                  _item(
                    icon: Icons.restaurant_menu_outlined,
                    label: 'canteen_menu'.tr,
                    onTap: () => Get.to(() => MenuScreen(job: _job)),
                  ),
                ] else ...[
                  _item(
                    icon: Icons.home_outlined,
                    label: 'tab_home'.tr,
                    index: 0,
                    onTap: () => _goToTab(0),
                  ),
                  _item(
                    icon: Icons.sensor_door_outlined,
                    label: 'tab_turnstile'.tr,
                    index: 1,
                    onTap: () => _goToTab(1),
                  ),
                  _item(
                    icon: Icons.receipt_long_outlined,
                    label: 'tab_payslip'.tr,
                    index: 2,
                    onTap: () => _goToTab(2),
                  ),
                  _item(
                    icon: Icons.beach_access_outlined,
                    label: 'tab_leave'.tr,
                    index: 3,
                    onTap: () => _goToTab(3),
                  ),
                  _item(
                    icon: Icons.restaurant_menu_outlined,
                    label: 'tab_menu'.tr,
                    index: 4,
                    onTap: () => _goToTab(4),
                  ),
                  if (isAdminRole(_job)) ...[
                    const Divider(height: 1),
                    _item(
                      icon: Icons.groups_outlined,
                      label: 'employee report'.tr,
                      onTap: () => Get.to(
                          () => MainPage2(fullName: _fullName, job: _job)),
                    ),
                    _item(
                      icon: Icons.badge_outlined,
                      label: 'attendance'.tr,
                      onTap: () => Get.to(() => const AttendanceScreen()),
                    ),
                  ],
                ],
                const Divider(height: 1),
                _item(
                  icon: Icons.campaign_outlined,
                  label: 'news'.tr,
                  onTap: () => Get.to(() => NewsScreen(job: _job)),
                ),
                _item(
                  icon: Icons.contact_phone_outlined,
                  label: 'directory'.tr,
                  onTap: () => Get.to(() => const DirectoryScreen()),
                ),
                _item(
                  icon: Icons.lock_outline,
                  label: 'password_change_title'.tr,
                  onTap: () => Get.to(() => ChangePasswordScreen(
                        fullName: _fullName,
                        job: _job,
                        currentPassword: '',
                        mandatory: false,
                      )),
                ),
                _item(
                  icon: Icons.pin_outlined,
                  label: 'pin_change_title'.tr,
                  onTap: () => Get.to(() => const PinScreen(mode: PinMode.change)),
                ),
                _item(
                  icon: ThemePref.icon(_themeMode),
                  label: '${'theme'.tr}: ${ThemePref.label(_themeMode)}',
                  onTap: _pickTheme,
                ),
                _item(
                  icon: Icons.translate,
                  label: _lang == "KZ" ? 'Русский' : 'Қазақша',
                  onTap: _changeLanguage,
                ),
                _item(
                  icon: Icons.info_outline,
                  label: 'about_title'.tr,
                  onTap: () => Get.to(() => const AboutScreen()),
                ),
                _item(
                  icon: Icons.logout,
                  label: 'log_out_title'.tr,
                  color: Colors.red.shade700,
                  onTap: () => confirmAndLogout(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _buildSocial(),
          _buildVersion(),
        ],
      ),
    );
  }

  /// Версия сборки внизу меню: в поддержке первым делом спрашивают её.
  /// По нажатию копируется, чтобы не переписывать вручную.
  Widget _buildVersion() {
    final label = '${'app_version'.tr} ${appVersionLabel()}';
    return SafeArea(
      top: false,
      child: InkWell(
        onTap: () => _copy(label),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10, top: 2),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: context.mutedColor),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(Dimensions.width20, 0, Dimensions.width20, 18),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.mainColor, AppColors.gradientColor2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(height: Dimensions.height30 / 2),
            CircleAvatar(
              radius: 26,
              backgroundColor: Colors.white.withOpacity(0.2),
              child: Text(
                _givenName.isNotEmpty ? _givenName[0].toUpperCase() : '?',
                style: const TextStyle(
                    color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onLongPress: () => _copy(_fullName),
              child: Text(
                _fullName,
                style: const TextStyle(
                    color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _job,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (_login != null && _login!.isNotEmpty) ...[
              const SizedBox(height: 6),
              GestureDetector(
                onTap: () => _copy(_login!),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.badge_outlined, size: 12, color: Colors.white54),
                    const SizedBox(width: 4),
                    Text(
                      _login!,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12, letterSpacing: 1),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSocial() {
    return SizedBox(
      height: Dimensions.height60 * 1.5,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButtonDrawer(
            icon: Image.asset('assets/youtube.png'),
            function: () => _open('https://www.youtube.com/@semeyengineering4367'),
          ),
          IconButtonDrawer(
            icon: Image.asset('assets/instagram.png'),
            function: () => _open('https://www.instagram.com/jscsemeyengineering/'),
          ),
          IconButtonDrawer(
            icon: Image.asset('assets/facebook.png'),
            function: () => _open('https://www.facebook.com/semeybtrz/'),
          ),
          IconButtonDrawer(
            icon: Image.asset('assets/web.png'),
            function: () => _open('https://se-btrz.com/'),
          ),
        ],
      ),
    );
  }

  /// Closes the drawer first, so the destination is not left behind it.
  Widget _item({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    int? index,
    Color? color,
  }) {
    final selected = index != null && index == widget.currentIndex;
    final tint = color ?? (selected ? AppColors.mainColor : context.mutedColor);
    return ListTile(
      dense: true,
      selected: selected,
      selectedTileColor: AppColors.mainColor.withOpacity(0.08),
      leading: Icon(icon, size: 21, color: tint),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          color: color ?? (selected ? AppColors.mainColor : context.inkColor),
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      onTap: () {
        Navigator.pop(context);
        HapticFeedback.selectionClick();
        // Re-tapping the section you are already on should just close.
        if (selected) return;
        onTap();
      },
    );
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('copied'.tr),
      duration: const Duration(seconds: 1),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _open(String url) async {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// Три варианта в одном листе: следовать телефону, всегда светлая,
  /// всегда тёмная. Список короткий, поэтому не диалог, а нижний лист —
  /// до него дотягивается большой палец.
  Future<void> _pickTheme() async {
    final chosen = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('theme'.tr,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold)),
              ),
            ),
            for (final mode in ThemeMode.values)
              RadioListTile<ThemeMode>(
                value: mode,
                groupValue: _themeMode,
                dense: true,
                secondary: Icon(ThemePref.icon(mode), size: 21),
                title: Text(ThemePref.label(mode),
                    style: const TextStyle(fontSize: 14)),
                onChanged: (value) => Navigator.pop(ctx, value),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    await ThemePref.write(chosen);
    if (mounted) setState(() => _themeMode = chosen);
  }

  Future<void> _changeLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final next = _lang == "KZ" ? "RU" : "KZ";
    await prefs.setString(AppValues.LANG, next);
    Get.updateLocale(Locale(next));
    if (mounted) setState(() => _lang = next);
  }
}
