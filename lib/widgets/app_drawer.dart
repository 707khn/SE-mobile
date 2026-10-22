import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../screens/admin_panel_screen.dart';
import '../screens/attendance_screen.dart';
import '../screens/business_trips_screen.dart';
import '../screens/directory_screen.dart';
import '../screens/it_requests_screen.dart';
import '../screens/assignments_screen.dart';
import '../screens/purchases_screen.dart';
import '../screens/news_screen.dart';
import '../screens/onboarding_screen.dart';
import '../screens/main_screen_2.dart';
import '../screens/menu_screen.dart';
import '../screens/settings_screen.dart';
import '../utils/app_version.dart';
import '../utils/colors.dart';
import '../utils/shell_tab.dart';
import '../utils/dimensions.dart';
import '../utils/logout_helper.dart';
import '../utils/open_external.dart';
import '../utils/role_helper.dart';
import '../utils/secure_storage_helper.dart';
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
    final fullName = await storage.getFullName();
    final job = await storage.getJob();
    final login = await storage.getLogin();
    if (!mounted) return;
    setState(() {
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
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              children: [
                // Разделы приложения — первыми и без заголовка: за ними в
                // меню и приходят. У администратора нижней панели нет, у
                // него на этом месте свои экраны.
                if (_isAdmin) ...[
                  _section('drawer_admin'.tr),
                  _item(
                    icon: Icons.admin_panel_settings_outlined,
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
                    _section('drawer_manager'.tr),
                    _item(
                      icon: Icons.groups_outlined,
                      label: 'drawer_staff_report'.tr,
                      onTap: () => Get.to(
                          () => MainPage2(fullName: _fullName, job: _job)),
                    ),
                    _item(
                      icon: Icons.insights_outlined,
                      label: 'attendance'.tr,
                      onTap: () => Get.to(() => const AttendanceScreen()),
                    ),
                  ],
                ],
                _section('drawer_company'.tr),
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
                  icon: Icons.support_agent_outlined,
                  label: 'it_title'.tr,
                  onTap: () => Get.to(() => const ItRequestsScreen()),
                ),
                _item(
                  icon: Icons.shopping_cart_outlined,
                  label: 'purch_title'.tr,
                  onTap: () => Get.to(() => const PurchasesScreen()),
                ),
                _item(
                  icon: Icons.task_alt,
                  label: 'asg_title'.tr,
                  onTap: () => Get.to(() => const AssignmentsScreen()),
                ),
                _item(
                  icon: Icons.flight_takeoff,
                  label: 'bt_title'.tr,
                  onTap: () => Get.to(() => const BusinessTripsScreen()),
                ),
                const SizedBox(height: 8),
                const Divider(height: 1, indent: 28, endIndent: 28),
                const SizedBox(height: 8),
                _item(
                  icon: Icons.waving_hand_outlined,
                  label: 'ob_title'.tr,
                  onTap: () => Get.to(() => const OnboardingScreen()),
                ),
                // Оформление, язык, пароль, код и «О программе» — на своём
                // экране: в меню они занимали половину списка.
                _item(
                  icon: Icons.settings_outlined,
                  label: 'drawer_settings'.tr,
                  onTap: () => Get.to(() => const SettingsScreen()),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // «Выйти» — не в общем списке, а всегда на виду внизу: в конце
          // длинного списка его приходилось искать прокруткой, а среди
          // настроек на него легко было нажать случайно.
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _item(
              icon: Icons.logout,
              label: 'log_out_title'.tr,
              color: Colors.red.shade700,
              onTap: () => confirmAndLogout(context),
            ),
          ),
          _buildSocial(),
          _buildVersion(),
        ],
      ),
    );
  }

  /// Подзаголовок группы пунктов.
  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 18, 20, 6),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: context.mutedColor,
        ),
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
      padding: EdgeInsets.fromLTRB(Dimensions.width20, 0, Dimensions.width20, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.mainColor, AppColors.gradientColor2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      // Значок рядом с именем, а не над ним: шапка в столбик занимала
      // пятую часть экрана, и пункты меню уезжали вниз.
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.only(top: Dimensions.height30 / 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.white.withOpacity(0.2),
                child: Text(
                  _givenName.isNotEmpty ? _givenName[0].toUpperCase() : '?',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onLongPress: () => _copy(_fullName),
                      child: Text(
                        _fullName,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_job.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        _job,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (_login != null && _login!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      GestureDetector(
                        onTap: () => _copy(_login!),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.badge_outlined,
                                size: 12, color: Colors.white54),
                            const SizedBox(width: 4),
                            Text(
                              _login!,
                              style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 12,
                                  letterSpacing: 1),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSocial() {
    return SizedBox(
      height: Dimensions.height60,
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
  ///
  /// Выбранный раздел подсвечен скруглённой плашкой с отступами, как в
  /// Material 3: полоса во всю ширину сливалась с соседними строками.
  Widget _item({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    int? index,
    Color? color,
    String? value,
  }) {
    final selected = index != null && index == widget.currentIndex;
    final tint = color ?? (selected ? AppColors.mainColor : context.mutedColor);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: ListTile(
        selected: selected,
        selectedTileColor: AppColors.mainColor.withOpacity(0.10),
        shape: const StadiumBorder(),
        visualDensity: const VisualDensity(vertical: -2),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        minLeadingWidth: 24,
        leading: Icon(selected ? _filled(icon) : icon, size: 22, color: tint),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            color: color ?? (selected ? AppColors.mainColor : context.inkColor),
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        trailing: value == null
            ? null
            : Text(value,
                style: TextStyle(fontSize: 13, color: context.mutedColor)),
        onTap: () {
          Navigator.pop(context);
          HapticFeedback.selectionClick();
          // Re-tapping the section you are already on should just close.
          if (selected) return;
          onTap();
        },
      ),
    );
  }

  /// Залитый вариант значка у выбранного раздела — как на нижней панели.
  static IconData _filled(IconData icon) {
    if (icon == Icons.home_outlined) return Icons.home;
    if (icon == Icons.sensor_door_outlined) return Icons.sensor_door;
    if (icon == Icons.receipt_long_outlined) return Icons.receipt_long;
    if (icon == Icons.beach_access_outlined) return Icons.beach_access;
    if (icon == Icons.restaurant_menu_outlined) return Icons.restaurant_menu;
    return icon;
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('copied'.tr),
      duration: const Duration(seconds: 1),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _open(String url) => openExternal(context, url);

}
