import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:se_mobile/screens/main_screen_1.dart';
import 'package:se_mobile/utils/dimensions.dart';
import 'package:se_mobile/widgets/custom_text.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/colors.dart';
import '../utils/logout_helper.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import '../widgets/icon_button_drawer.dart';
import 'leave_screen.dart';
import 'main_screen_2.dart';
import 'attendance_screen.dart';
import 'menu_screen.dart';
import 'payslip_screen.dart';
import 'start_screen.dart';
import '../utils/app_theme.dart';

class AdminPage extends StatefulWidget {
  const AdminPage({super.key, required this.fullName, required this.job});

  final String fullName;
  final String job;

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  static String _lang = "";
  String? _login;
  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    prefs = await SharedPreferences.getInstance();
    if (prefs.getString(AppValues.LANG) == null) {
      prefs.setString(AppValues.LANG, "RU");
    }
    final login = await SecureStorageHelper.instance.getLogin();
    setState(() {
      _lang = prefs.getString(AppValues.LANG)!;
      _login = login;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: BigText(content: "main_menu".tr, fontWeight: FontWeight.bold),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'log_out_title'.tr,
            onPressed: _exit,
          ),
        ],
      ),
      drawer: Theme(
        data: Theme.of(context).copyWith(
          canvasColor: Theme.of(context).scaffoldBackgroundColor,
        ),
        child: SizedBox(
          width: Dimensions.width120 * 2.5,
          child: Drawer(
            child: Column(
              children: <Widget>[
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: <Widget>[
                      SizedBox(
                        height: Dimensions.height120 * 2,
                        child: DrawerHeader(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.secondary,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                children: [
                                  GestureDetector(
                                    onLongPress: () {
                                      Clipboard.setData(ClipboardData(text: widget.fullName));
                                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                        content: Text('copied'.tr),
                                        duration: const Duration(seconds: 1),
                                        behavior: SnackBarBehavior.floating,
                                      ));
                                    },
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        BigText(
                                          content: widget.fullName,
                                          color: AppColors.niceWhite,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        MediumText(
                                          content: widget.job,
                                          color: AppColors.niceWhite,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (_login != null && _login!.isNotEmpty) ...[
                                          const SizedBox(height: 2),
                                          GestureDetector(
                                            onTap: () {
                                              Clipboard.setData(ClipboardData(text: _login!));
                                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                                content: Text('copied'.tr),
                                                duration: const Duration(seconds: 1),
                                                behavior: SnackBarBehavior.floating,
                                              ));
                                            },
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(Icons.badge_outlined, size: 12, color: Colors.white54),
                                                const SizedBox(width: 4),
                                                Text(
                                                  _login!,
                                                  style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 12,
                                                    letterSpacing: 1,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  Row(
                                    children: [
                                      Padding(
                                        padding: EdgeInsets.only(right: Dimensions.width20 / 1.5),
                                        child: GestureDetector(
                                          onTap: _changeLanguage,
                                          child: _lang == "KZ"
                                              ? SizedBox(
                                                  width: Dimensions.width20 * 1.25,
                                                  height: Dimensions.height30 * 1.25,
                                                  child: Image.asset('assets/ru.png'),
                                                )
                                              : SizedBox(
                                                  width: Dimensions.width20 * 1.25,
                                                  height: Dimensions.height30 * 1.25,
                                                  child: Image.asset('assets/kz.png'),
                                                ),
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: _exit,
                                        child: Image.asset(
                                          'assets/door.png',
                                          color: AppColors.niceWhite,
                                          height: Dimensions.height30 / 1.1,
                                        ),
                                      )
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      ListTile(
                        leading: Icon(Icons.restaurant_menu, color: context.accentColor),
                        title: BigText(content: 'canteen_menu'.tr),
                        subtitle: Text('canteen_subtitle'.tr, style: const TextStyle(fontSize: 11)),
                        onTap: () {
                          Navigator.pop(context);
                          Get.to(() => const MenuScreen());
                        },
                      ),
                      ListTile(
                        leading: Icon(Icons.receipt_long, color: context.accentColor),
                        title: BigText(content: 'payslip'.tr),
                        subtitle: Text('payslip_subtitle'.tr, style: const TextStyle(fontSize: 11)),
                        onTap: () {
                          Navigator.pop(context);
                          Get.to(() => const PayslipPage());
                        },
                      ),
                      ListTile(
                        leading: Icon(Icons.beach_access, color: context.accentColor),
                        title: BigText(content: 'leave_sick_days'.tr),
                        subtitle: Text('leave_subtitle'.tr, style: const TextStyle(fontSize: 11)),
                        onTap: () {
                          Navigator.pop(context);
                          Get.to(() => const LeavePage());
                        },
                      ),
                    ],
                  ),
                ),
                Container(
                  height: Dimensions.height30 / 15,
                  width: Dimensions.width120 * 2,
                  color: Colors.black26,
                ),
                Container(
                  padding: EdgeInsets.only(
                    bottom: Dimensions.height30,
                    top: Dimensions.height30 / 2,
                  ),
                  height: Dimensions.height60 * 1.5,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButtonDrawer(
                        icon: Image.asset('assets/youtube.png'),
                        function: () async {
                          await launchUrl(Uri.parse('https://www.youtube.com/@semeyengineering4367'), mode: LaunchMode.externalApplication);
                        },
                      ),
                      IconButtonDrawer(
                        icon: Image.asset('assets/instagram.png'),
                        function: () async {
                          await launchUrl(Uri.parse('https://www.instagram.com/jscsemeyengineering/'), mode: LaunchMode.externalApplication);
                        },
                      ),
                      IconButtonDrawer(
                        icon: Image.asset('assets/facebook.png'),
                        function: () async {
                          await launchUrl(Uri.parse('https://www.facebook.com/semeybtrz/'), mode: LaunchMode.externalApplication);
                        },
                      ),
                      IconButtonDrawer(
                        icon: Image.asset('assets/web.png'),
                        function: () async {
                          await launchUrl(Uri.parse('https://se-btrz.com/'), mode: LaunchMode.externalApplication);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: Dimensions.width20,
            vertical: Dimensions.height30,
          ),
          child: Column(
            children: [
              _buildGreeting(),
              SizedBox(height: Dimensions.height30 / 2),
              GridView.count(
                crossAxisCount: 2,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
                childAspectRatio: 1.05,
                children: [
                  _buildGridCard(
                    icon: Icons.person,
                    label: "self report".tr,
                    subtitle: "self_report_subtitle".tr,
                    color: const Color(0xFF1565C0),
                    onTap: () => Get.to(() => MainPage1(fullName: widget.fullName, job: widget.job)),
                  ),
                  _buildGridCard(
                    icon: Icons.groups,
                    label: "employee report".tr,
                    subtitle: "employee_report_subtitle".tr,
                    color: const Color(0xFF6A1B9A),
                    onTap: () => Get.to(() => MainPage2(fullName: widget.fullName, job: widget.job)),
                  ),
                  _buildGridCard(
                    icon: Icons.receipt_long,
                    label: "payslip".tr,
                    subtitle: "payslip_subtitle".tr,
                    color: AppColors.mainColor,
                    onTap: () => Get.to(() => const PayslipPage()),
                  ),
                  _buildGridCard(
                    icon: Icons.beach_access,
                    label: "leave_sick_days".tr,
                    subtitle: "leave_subtitle".tr,
                    color: const Color(0xFFE65100),
                    onTap: () => Get.to(() => const LeavePage()),
                  ),
                  _buildGridCard(
                    icon: Icons.restaurant_menu,
                    label: "canteen_menu".tr,
                    subtitle: "canteen_subtitle".tr,
                    color: const Color(0xFFC62828),
                    onTap: () => Get.to(() => const MenuScreen()),
                  ),
                  _buildGridCard(
                    icon: Icons.badge_outlined,
                    label: "attendance".tr,
                    subtitle: "attendance_subtitle".tr,
                    color: const Color(0xFF00695C),
                    onTap: () => Get.to(() => const AttendanceScreen()),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGridCard({
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
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
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 28),
              ),
              const SizedBox(height: 10),
              Text(
                label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 11, color: context.mutedColor),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGreeting() {
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
    // ФИО format is "Фамилия Имя Отчество" — greet by the given name (2nd word),
    // falling back to the first word for single-word names.
    final _nameParts = widget.fullName.trim().split(RegExp(r'\s+'));
    final firstName = (_nameParts.length >= 2 && _nameParts[1].isNotEmpty)
        ? _nameParts[1]
        : (_nameParts.isNotEmpty ? _nameParts.first : widget.fullName);
    final days = _lang == 'RU'
        ? ['Понедельник', 'Вторник', 'Среда', 'Четверг', 'Пятница', 'Суббота', 'Воскресенье']
        : ['Дүйсенбі', 'Сейсенбі', 'Сәрсенбі', 'Бейсенбі', 'Жұма', 'Сенбі', 'Жексенбі'];
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
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${greetKey.tr} $firstName!',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.job,
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$dayName, $dateStr',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  _changeLanguage() async {
    Navigator.pop(context);
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_lang == "KZ") {
      prefs.setString(AppValues.LANG, "RU");
      Get.updateLocale(Locale(prefs.getString(AppValues.LANG)!));
      if (mounted) setState(() => _lang = prefs.getString(AppValues.LANG)!);
    } else if (_lang == "RU") {
      prefs.setString(AppValues.LANG, "KZ");
      Get.updateLocale(Locale(prefs.getString(AppValues.LANG)!));
      if (mounted) setState(() => _lang = prefs.getString(AppValues.LANG)!);
    }
  }

  _exit() => confirmAndLogout(context);
}
