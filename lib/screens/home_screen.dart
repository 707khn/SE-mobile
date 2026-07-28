import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/logout_helper.dart';
import '../utils/role_helper.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import 'admin_panel_screen.dart';
import 'attendance_screen.dart';
import 'main_screen_2.dart';

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

class _HomeScreenState extends State<HomeScreen> {
  String _lang = "RU";
  String? _login;

  @override
  void initState() {
    super.initState();
    _initPrefs();
  }

  Future<void> _initPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(AppValues.LANG) == null) {
      prefs.setString(AppValues.LANG, "RU");
    }
    final login = await SecureStorageHelper.instance.getLogin();
    if (mounted) {
      setState(() {
        _lang = prefs.getString(AppValues.LANG)!;
        _login = login;
      });
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
      backgroundColor: AppColors.niceWhite,
      appBar: AppBar(
        // The shell is pushed on top of the login screen, so Navigator would
        // otherwise offer a back arrow that signs the user out.
        automaticallyImplyLeading: false,
        title: Text('main_menu'.tr,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: _lang == "KZ" ? "Русский" : "Қазақша",
            icon: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Image.asset(_lang == "KZ" ? 'assets/ru.png' : 'assets/kz.png'),
            ),
            onPressed: _changeLanguage,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'log_out_title'.tr,
            onPressed: () => confirmAndLogout(context),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: Dimensions.width20,
          vertical: Dimensions.height30 / 2,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildGreetingCard(),
            SizedBox(height: Dimensions.height30 / 1.2),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text(
                'quick_access'.tr,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey.shade800,
                ),
              ),
            ),
            GridView.count(
              // A lone admin card reads better as a full-width banner than as
              // one square in a two-column grid.
              crossAxisCount: _isAdmin ? 1 : 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: _isAdmin ? 2.4 : 1.1,
              children: [
                // The admin has no attendance, payslip or leave of their own —
                // the panel is the whole job, so it is the only card shown.
                if (_isAdmin)
                  _buildActionCard(
                    icon: Icons.admin_panel_settings,
                    label: 'admin_panel'.tr,
                    subtitle: 'admin_panel_subtitle'.tr,
                    color: const Color(0xFF4527A0),
                    onTap: () => Get.to(() => const AdminPanelScreen()),
                  ),
                if (!_isAdmin) ...[
                  _buildActionCard(
                    icon: Icons.sensor_door,
                    label: 'tab_turnstile'.tr,
                    subtitle: 'self_report_subtitle'.tr,
                    color: const Color(0xFF1565C0),
                    onTap: () => widget.onNavigate(1),
                  ),
                  _buildActionCard(
                    icon: Icons.receipt_long,
                    label: 'tab_payslip'.tr,
                    subtitle: 'payslip_subtitle'.tr,
                    color: AppColors.mainColor,
                    onTap: () => widget.onNavigate(2),
                  ),
                  _buildActionCard(
                    icon: Icons.beach_access,
                    label: 'tab_leave'.tr,
                    subtitle: 'leave_subtitle'.tr,
                    color: const Color(0xFFE65100),
                    onTap: () => widget.onNavigate(3),
                  ),
                  _buildActionCard(
                    icon: Icons.restaurant_menu,
                    label: 'tab_menu'.tr,
                    subtitle: 'canteen_subtitle'.tr,
                    color: const Color(0xFFC62828),
                    onTap: () => widget.onNavigate(4),
                  ),
                ],
                // Managers keep their team-wide screens, now inside the shell.
                if (!_isAdmin && isAdminRole(widget.job)) ...[
                  _buildActionCard(
                    icon: Icons.groups,
                    label: 'employee report'.tr,
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
    final days = _lang == 'KZ'
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
                    Text(
                      '$dayName, $dateStr',
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
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
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _changeLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final next = _lang == "KZ" ? "RU" : "KZ";
    prefs.setString(AppValues.LANG, next);
    Get.updateLocale(Locale(next));
    if (mounted) setState(() => _lang = next);
  }
}
