import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../requests/home_request.dart';
import '../utils/app_update.dart';
import '../utils/colors.dart';
import '../utils/lang.dart';
import '../utils/notice_badge.dart';
import '../utils/open_external.dart';
import '../utils/dimensions.dart';
import '../utils/role_helper.dart';
import '../utils/variables.dart';
import '../widgets/app_drawer.dart';
import '../widgets/notification_bell.dart';
import 'admin_panel_screen.dart';
import 'attendance_screen.dart';
import 'it_requests_screen.dart';
import 'purchases_screen.dart';
import 'menu_screen.dart';
import 'main_screen_2.dart';
import '../utils/app_theme.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    Key? key,
    required this.fullName,
    required this.job,
    required this.onNavigate,
  }) : super(key: key);

  final String fullName;
  final String job;
  final ValueChanged<int> onNavigate;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  String _lang = Lang.ru;

  /// По строке на раздел: когда прошёл турникет, за какой месяц листок,
  /// сколько отпуска, что в столовой. Нет связи и нет сохранённой — карточки
  /// остаются с обычными подписями.
  HomeSummary? _summary;

  /// Сборка новее установленной, если она лежит на сервере и человек её ещё
  /// не отложил.
  AppUpdate? _update;

  /// Пока приложение открыто, колокольчик переспрашивает сервер сам:
  /// пуша нет, и иначе о новом листке человек узнал бы, только выйдя и
  /// вернувшись.
  Timer? _noticeTimer;
  static const _noticeEvery = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPrefs();
    _checkForUpdate();
    _loadSummary();
    _startNoticeTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _noticeTimer?.cancel();
    super.dispose();
  }

  void _startNoticeTimer() {
    NoticeBadge.refresh();
    _noticeTimer?.cancel();
    _noticeTimer = Timer.periodic(_noticeEvery, (_) => NoticeBadge.refresh());
  }

  /// Вернулся в приложение — сводка могла устареть: утром открыл, в обед
  /// прошёл турникет, а на экране всё ещё «вход 07:52».
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadSummary();
      _startNoticeTimer();
    } else if (state == AppLifecycleState.paused) {
      // В фоне спрашивать незачем: число всё равно никто не видит.
      _noticeTimer?.cancel();
    }
  }

  Future<void> _loadSummary() async {
    // У администратора нет ни проходов, ни листков, ни отпуска.
    if (_isAdmin) return;
    final summary = await fetchHomeSummary();
    if (mounted && summary != null) setState(() => _summary = summary);
  }

  /// Раздача приложения руками — причина, по которой обязательную проверку
  /// пропуска до сих пор нельзя включить: у необновившихся всё перестанет
  /// работать, а обновиться им было неоткуда. Спрашиваем сервер сами.
  Future<void> _checkForUpdate() async {
    final update = await AppUpdate.check();
    if (update == null || !mounted) return;
    if (await update.isDismissed()) return;
    if (mounted) setState(() => _update = update);
  }

  Future<void> _initPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(AppValues.LANG) == null) {
      prefs.setString(AppValues.LANG, Lang.ru);
    }
    if (mounted) {
      setState(() => _lang = Lang.code(prefs.getString(AppValues.LANG)));
    }
  }

  bool get _isAdmin => isSystemAdmin(widget.job);

  // For Kazakh ФИО format (Фамилия Имя Отчество), the given name is the
  // second word. Fall back to the first word for single-word names.
  String get _givenName {
    final parts = widget.fullName.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2 && parts[1].isNotEmpty) return parts[1];
    return parts.isNotEmpty ? parts.first : widget.fullName;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      drawer: AppDrawer(onNavigate: widget.onNavigate, currentIndex: 0),
      appBar: AppBar(
        // Explicit leading: the shell sits on top of the login screen, so an
        // implied leading would be a back arrow that signs the user out.
        automaticallyImplyLeading: false,
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: Text('main_menu'.tr,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        // Language and logout live in the drawer now, so they are in the same
        // place on every section instead of only here.
        actions: [NotificationBell(job: widget.job)],
      ),
      // Потянуть вниз — обновить сводку.
      body: RefreshIndicator(
        onRefresh: () => Future.wait([_loadSummary(), NoticeBadge.refresh()]),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(
            horizontal: Dimensions.width20,
            vertical: Dimensions.height30 / 2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildGreetingCard(),
              if (_update != null) ...[
                SizedBox(height: Dimensions.height30 / 1.5),
                _buildUpdateCard(_update!),
              ],
              SizedBox(height: Dimensions.height30 / 1.2),
              GridView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                // Высота ячейки задана прямо, а не через childAspectRatio.
                // Пропорция привязывает высоту к ширине экрана, а нужного места
                // требует содержимое: у казахских подписей по две строки, и на
                // телефоне с крупным системным шрифтом карточки не помещались —
                // отсюда красная полоса «BOTTOM OVERFLOWED».
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  // The admin's few cards read better as full-width banners than
                  // as squares in a two-column grid.
                  crossAxisCount: _isAdmin ? 1 : 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  mainAxisExtent: _cardHeight(context),
                ),
                children: [
                  // The admin has no attendance, payslip or leave of their own,
                  // so only the two things they actually do are shown.
                  if (_isAdmin) ...[
                    _buildActionCard(
                      icon: Icons.admin_panel_settings,
                      label: 'admin_panel'.tr,
                      subtitle: 'admin_panel_subtitle'.tr,
                      color: const Color(0xFF4527A0),
                      onTap: () => Get.to(() => const AdminPanelScreen()),
                    ),
                    // The admin has no tabs, so the canteen menu is pushed as a
                    // route; they need it to fix the menu when the technologist
                    // cannot.
                    _buildActionCard(
                      icon: Icons.restaurant_menu,
                      label: 'canteen_menu'.tr,
                      subtitle: 'canteen_subtitle'.tr,
                      color: const Color(0xFFC62828),
                      onTap: () => Get.to(() => MenuScreen(job: widget.job)),
                    ),
                  ],
                  if (!_isAdmin) ...[
                    _buildActionCard(
                      icon: Icons.sensor_door,
                      label: 'tab_turnstile'.tr,
                      live: _accessLine,
                      subtitle: 'self_report_subtitle'.tr,
                      color: const Color(0xFF1565C0),
                      onTap: () => widget.onNavigate(1),
                    ),
                    _buildActionCard(
                      icon: Icons.receipt_long,
                      label: 'tab_payslip'.tr,
                      live: _payslipLine,
                      subtitle: 'payslip_subtitle'.tr,
                      color: AppColors.mainColor,
                      onTap: () => widget.onNavigate(2),
                    ),
                    _buildActionCard(
                      icon: Icons.beach_access,
                      label: 'tab_leave'.tr,
                      live: _leaveLine,
                      subtitle: 'leave_subtitle'.tr,
                      color: const Color(0xFFE65100),
                      onTap: () => widget.onNavigate(3),
                    ),
                    _buildActionCard(
                      icon: Icons.restaurant_menu,
                      label: 'tab_menu'.tr,
                      live: _menuLine,
                      subtitle: 'canteen_subtitle'.tr,
                      color: const Color(0xFFC62828),
                      onTap: () => widget.onNavigate(4),
                    ),
                    _buildActionCard(
                      icon: Icons.support_agent,
                      label: 'it_title'.tr,
                      subtitle: 'it_home_subtitle'.tr,
                      color: const Color(0xFF37474F),
                      onTap: () => Get.to(() => const ItRequestsScreen()),
                    ),
                    _buildActionCard(
                      icon: Icons.shopping_cart_outlined,
                      label: 'purch_title'.tr,
                      subtitle: 'purch_home_subtitle'.tr,
                      color: const Color(0xFFAD1457),
                      onTap: () => Get.to(() => const PurchasesScreen()),
                    ),
                  ],
                  // Managers keep their team-wide screens, now inside the shell.
                  if (!_isAdmin && isAdminRole(widget.job)) ...[
                    _buildActionCard(
                      icon: Icons.groups,
                      label: 'drawer_staff_report'.tr,
                      subtitle: 'employee_report_subtitle'.tr,
                      color: const Color(0xFF6A1B9A),
                      onTap: () => Get.to(() => MainPage2(
                            fullName: widget.fullName,
                            job: widget.job,
                          )),
                    ),
                    _buildActionCard(
                      icon: Icons.badge_outlined,
                      label: 'attendance'.tr,
                      subtitle: 'attendance_subtitle'.tr,
                      color: const Color(0xFF00695C),
                      onTap: () => Get.to(() => const AttendanceScreen()),
                    ),
                  ],
                ],
              ),
              SizedBox(height: Dimensions.height30),
            ],
          ),
        ),
      ),
    );
  }

  bool _isToday(DateTime day) {
    final now = DateTime.now();
    return day.year == now.year && day.month == now.month && day.day == now.day;
  }

  String? get _accessLine {
    final access = _summary?.access;
    if (access == null) return null;
    final String times;
    if (access.firstIn != null && access.lastOut != null) {
      times = '${access.firstIn} – ${access.lastOut}';
    } else if (access.firstIn != null) {
      times = 'home_in_only'.trParams({'time': access.firstIn!});
    } else if (access.lastOut != null) {
      times = 'home_out_only'.trParams({'time': access.lastOut!});
    } else {
      return null;
    }
    final day = _isToday(access.date)
        ? 'home_today'.tr
        : DateFormat('dd.MM').format(access.date);
    return '$day · $times';
  }

  String? get _payslipLine {
    final month = _summary?.payslip;
    if (month == null) return null;
    return 'home_payslip_for'.trParams(
        {'period': DateFormat('LLLL yyyy', Lang.dates).format(month)});
  }

  String? get _leaveLine {
    final days = _summary?.leaveDays;
    if (days == null) return null;
    return 'home_leave_days'.trParams({'days': '$days'});
  }

  String? get _menuLine {
    final summary = _summary;
    if (summary == null) return null;
    if (summary.menuCount == 0) return 'home_menu_none'.tr;
    final shown = summary.dishes.take(2).toList();
    final more = summary.menuCount - shown.length;
    return more > 0 ? '${shown.join(', ')} +$more' : shown.join(', ');
  }

  /// Высота карточки быстрого доступа.
  ///
  /// Складывается из того, что внутри: кружок с иконкой, две строки названия
  /// и две строки пояснения. Текст растёт вместе с системным размером шрифта
  /// (приложение разрешает до 1,3), а иконка — нет, поэтому масштабируется
  /// только текстовая часть.
  double _cardHeight(BuildContext context) {
    const padding = 12 * 2;
    const iconCircle = 11 * 2 + 26;
    const gaps = 8 + 3;
    // Четыре строки: две по 13 и две по 11, с межстрочным запасом.
    const textLines = (13 * 2 + 11 * 2) * 1.4;
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    return padding + iconCircle + gaps + textLines * scale;
  }

  /// Полоса про новую сборку.
  ///
  /// Не диалог: закрывать его пришлось бы каждому при каждом запуске, а
  /// откладывать человек имеет право. «Позже» откладывает именно эту сборку —
  /// следующая спросит снова.
  Widget _buildUpdateCard(AppUpdate update) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.mainColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.mainColor.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.system_update_outlined,
              color: context.accentColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('update_available'.trParams({'version': update.label}),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  update.sizeLabel.isEmpty
                      ? 'update_hint'.tr
                      : '${'update_hint'.tr} · ${update.sizeLabel}',
                  style: TextStyle(fontSize: 12, color: context.mutedColor),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () => openExternal(context, update.url),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text('update_download'.tr,
                          style: const TextStyle(fontSize: 13)),
                    ),
                    TextButton(
                      onPressed: () async {
                        await update.dismiss();
                        if (mounted) setState(() => _update = null);
                      },
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text('later'.tr,
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGreetingCard() {
    final now = DateTime.now();
    final hour = now.hour;
    final String greetKey;
    if (hour < 12) {
      greetKey = 'greeting_morning';
    } else if (hour < 18) {
      greetKey = 'greeting_afternoon';
    } else {
      greetKey = 'greeting_evening';
    }
    final days = Lang.isKazakh(_lang)
        ? ['Дүйсенбі', 'Сейсенбі', 'Сәрсенбі', 'Бейсенбі', 'Жұма', 'Сенбі', 'Жексенбі']
        : ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье'];
    final dayName = days[now.weekday - 1];
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}.${now.month.toString().padLeft(2, '0')}.${now.year}';

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Dimensions.width20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.mainColor, AppColors.gradientColor2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.mainColor.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${greetKey.tr} $_givenName!',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.job,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    const Icon(Icons.calendar_today,
                        size: 13, color: Colors.white60),
                    const SizedBox(width: 5),
                    // «Понедельник» и «Воскресенье» длиннее прочих дней: на
                    // узком телефоне с крупным шрифтом строка уходила за
                    // край. Теперь переносится.
                    Flexible(
                      child: Text(
                        '$dayName, $dateStr',
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _givenName.isNotEmpty ? _givenName[0].toUpperCase() : '?',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionCard({
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
    String? live,
  }) {
    final tone = context.readable(color);
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: tone.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: tone, size: 26),
              ),
              const SizedBox(height: 8),
              // Flexible — страховка на случай, если расчёт высоты где-то
              // всё-таки не сойдётся: текст ужмётся с многоточием, а красной
              // полосы переполнения не появится.
              // Название место не делит: Flexible у обоих текстов делил его
              // пополам, и вторая строка названия обрезалась на середине.
              // Ужимается только пояснение.
              Text(
                label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              Flexible(
                // Живая строка — цветом раздела, чтобы отличалась от
                // пояснения, которое стоит, пока сводки нет.
                child: Text(
                  live ?? subtitle,
                  style: live == null
                      ? TextStyle(fontSize: 11, color: context.mutedColor)
                      : TextStyle(
                          fontSize: 11, color: tone, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

}
