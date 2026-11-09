import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../chat/chat_bridge.dart';
import '../chat/chat_config.dart';

import '../screens/admin_panel_screen.dart';
import '../screens/business_trips_screen.dart';
import '../screens/directory_screen.dart';
import '../screens/it_requests_screen.dart';
import '../screens/assignments_screen.dart';
import '../screens/tech_screen.dart';
import '../screens/news_screen.dart';
import '../screens/payslips_admin_screen.dart';
import '../screens/main_screen_2.dart';
import '../screens/medical_screen.dart';
import '../screens/menu_screen.dart';
import '../screens/settings_screen.dart';
import '../utils/app_version.dart';
import '../utils/colors.dart';
import '../utils/desktop.dart';
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
  const AppDrawer(
      {Key? key, this.onNavigate, this.currentIndex, this.permanent = false})
      : super(key: key);

  /// Постоянная панель слева на компьютере (см. DesktopLayout), а не
  /// выдвижное меню. Стоит над навигатором: закрывать ей нечего, выбранный
  /// раздел она узнаёт сама, а открытые поверх экраны сворачивает.
  final bool permanent;

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
    if (widget.onNavigate == null && !widget.permanent) {
      Get.until((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.permanent) return Drawer(child: _buildContent());
    // На панели выбранный раздел подсвечен всегда — тот, что открыт сейчас.
    return Material(
      color: context.cardSurface,
      child: ValueListenableBuilder<int>(
        valueListenable: ShellTab.selected,
        builder: (context, _, __) => _buildContent(),
      ),
    );
  }

  /// Вкладка, открытая сейчас: у выдвижного меню её называет экран, у
  /// постоянной панели — оболочка. У администратора вкладок нет.
  int? get _currentIndex => widget.permanent
      ? (_isAdmin ? null : ShellTab.selected.value)
      : widget.currentIndex;

  Widget _buildContent() {
    return Column(
        children: [
          _buildHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              // Пункты разбиты на группы тонкой чертой, без заголовков:
              // подписи «Руководителю», «Предприятие», «Мои дела» занимали
              // место и не помогали найти пункт — «Заявки в ОИТиС» стояли в
              // одной группе, а «Техника и отключения» в другой. Теперь
              // рядом стоит то, что по смыслу вместе, а сверху — то, куда
              // заходят чаще.
              children: [
                // Разделы приложения — первыми: за ними в меню и приходят.
                // Порядок — как на нижней панели телефона. Пункты начальника
                // и расчётной группы — сразу под своим разделом: проходы
                // отдела под своими проходами, листки всех под своим листком.
                // У администратора нижней панели нет, у него на этом месте
                // свои экраны.
                if (_isAdmin) ...[
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
                  if (_uploadsPayslips) _payslipsAdminItem(),
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
                  if (isManager(_job))
                    _item(
                      icon: Icons.groups_outlined,
                      label: 'drawer_staff_report'.tr,
                      onTap: () => Get.to(
                          () => MainPage2(fullName: _fullName, job: _job)),
                    ),
                  _item(
                    icon: Icons.receipt_long_outlined,
                    label: 'tab_payslip'.tr,
                    index: 2,
                    onTap: () => _goToTab(2),
                  ),
                  if (_uploadsPayslips) _payslipsAdminItem(),
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
                  if (chatEnabled)
                    _item(
                      icon: Icons.forum_outlined,
                      label: 'tab_chat'.tr,
                      index: ChatBridge.tabIndex,
                      onTap: () => _goToTab(ChatBridge.tabIndex),
                    ),
                ],
                // Свои дела по работе: что поручили, куда ехать, когда к
                // врачу.
                _groupBreak(),
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
                _item(
                  icon: Icons.health_and_safety_outlined,
                  label: 'md_title'.tr,
                  onTap: () => Get.to(() => const MedicalScreen()),
                ),
                // Что происходит на заводе и как кого найти.
                _groupBreak(),
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
                // Всё, что к ОИТиС: заявка, своя техника, отключения.
                _groupBreak(),
                _item(
                  icon: Icons.support_agent_outlined,
                  label: 'it_title'.tr,
                  onTap: () => Get.to(() => const ItRequestsScreen()),
                ),
                _item(
                  icon: Icons.devices_outlined,
                  label: 'ta_title'.tr,
                  onTap: () => Get.to(() => const TechScreen()),
                ),
                _groupBreak(),
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
              // Выход спрашивает подтверждение: открытые экраны до ответа
              // не трогаем.
              navigates: false,
              // Панель стоит над навигатором: окно открываем через него.
              onTap: () => confirmAndLogout(
                  widget.permanent ? (Get.context ?? context) : context),
            ),
          ),
          _buildSocial(),
          _buildVersion(),
        ],
    );
  }

  /// Черта между группами пунктов.
  Widget _groupBreak() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(height: 1, indent: 28, endIndent: 28),
      );

  /// Листки из 1С загружают с компьютера бухгалтерии: файл сохраняется там,
  /// и на телефоне его нет.
  bool get _uploadsPayslips => isDesktop && canUploadPayslips(_job);

  Widget _payslipsAdminItem() => _item(
        icon: Icons.upload_file_outlined,
        label: 'psa_title'.tr,
        onTap: () => Get.to(() => const PayslipsAdminScreen()),
      );

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

  // Размеры Dimensions берутся от экрана навигатора. Постоянная панель стоит
  // вне его, и когда навигатор при входе переезжает к ней в соседи, спросить
  // его о размере в этот момент нельзя. Да и на мониторе масштаб под
  // телефон не нужен.
  double get _side => widget.permanent ? 20 : Dimensions.width20;
  double get _headerTop => widget.permanent ? 18 : Dimensions.height30 / 2;
  double? get _socialSize => widget.permanent ? 28 : null;

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(_side, 0, _side, 16),
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
          padding: EdgeInsets.only(top: _headerTop),
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
      height: widget.permanent ? 60 : Dimensions.height60,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButtonDrawer(
            icon: Image.asset('assets/youtube.png'),
            size: _socialSize,
            function: () => _open('https://www.youtube.com/@semeyengineering4367'),
          ),
          IconButtonDrawer(
            icon: Image.asset('assets/instagram.png'),
            size: _socialSize,
            function: () => _open('https://www.instagram.com/jscsemeyengineering/'),
          ),
          IconButtonDrawer(
            icon: Image.asset('assets/facebook.png'),
            size: _socialSize,
            function: () => _open('https://www.facebook.com/semeybtrz/'),
          ),
          IconButtonDrawer(
            icon: Image.asset('assets/web.png'),
            size: _socialSize,
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
    bool navigates = true,
  }) {
    final selected = index != null && index == _currentIndex;
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
          HapticFeedback.selectionClick();
          if (widget.permanent) {
            // Раздел из панели открывается вместо того, что открыто сейчас,
            // а не стопкой поверх: иначе после десятка переходов «назад»
            // пришлось бы нажимать десять раз.
            if (navigates) Get.until((route) => route.isFirst);
            if (!selected) onTap();
            return;
          }
          Navigator.pop(context);
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
