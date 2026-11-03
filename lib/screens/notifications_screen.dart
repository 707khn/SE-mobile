import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/notifications_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../utils/notice_badge.dart';
import '../utils/role_helper.dart';
import '../utils/shell_tab.dart';
import '../widgets/load_error_view.dart';
import 'medical_screen.dart';
import 'menu_screen.dart';
import 'news_admin_screen.dart';
import 'it_request_detail_screen.dart';
import 'it_requests_screen.dart';
import 'business_trip_detail_screen.dart';
import 'business_trips_screen.dart';
import 'reception_screen.dart';
import 'tech_screen.dart';
import 'payslip_question_detail_screen.dart';
import 'payslip_questions_screen.dart';
import 'purchase_detail_screen.dart';
import 'assignment_detail_screen.dart';
import 'assignments_screen.dart';
import 'purchases_screen.dart';
import 'news_screen.dart';
import 'rollout_screen.dart';

/// Оповещения: что нового с прошлого раза.
///
/// Открыл — значит, прочитал: отметка ставится сразу, а новое остаётся
/// выделенным до ухода с экрана, чтобы было видно, что именно пришло.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({Key? key, this.job = ''}) : super(key: key);

  final String job;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  NoticeFeed? _feed;
  bool _loading = true;
  LoadProblem? _problem;

  bool get _isAdmin => isSystemAdmin(widget.job);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _problem = null;
    });
    final result = await fetchNotices();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _feed = result.feed ?? _feed;
      _problem = result.feed == null ? result.problem : null;
    });
    final feed = result.feed;
    if (feed == null) return;
    final newest = feed.newestId;
    if (feed.unread > 0 && newest != null && await markNoticesSeen(newest)) {
      // Поломки сервера отметкой не гасятся: они пропадут, когда их починят.
      NoticeBadge.count.value = feed.system.length;
    } else {
      NoticeBadge.count.value = feed.unread + feed.system.length;
    }
  }

  /// Перейти туда, о чём оповещение.
  void _open(AppNotice notice) {
    switch (notice.kind) {
      case 'payslip':
        _toTab(2);
      case 'menu':
        if (_isAdmin) {
          Get.to(() => MenuScreen(job: widget.job));
        } else {
          _toTab(4);
        }
      case 'queue':
        Get.to(() => const NewsAdminScreen());
      case 'news':
        Get.to(() => NewsScreen(job: widget.job));
      case 'it':
        final id = int.tryParse(notice.ref ?? '');
        Get.to(() => id == null
            ? const ItRequestsScreen()
            : ItRequestDetailScreen(requestId: id));
      case 'trip':
        final id = int.tryParse(notice.ref ?? '');
        Get.to(() => id == null
            ? const BusinessTripsScreen()
            : BusinessTripDetailScreen(tripId: id));
      case 'outage':
      case 'itasset':
        Get.to(() => const TechScreen());
      case 'reception':
        Get.to(() => const ReceptionScreen());
      case 'medical':
        Get.to(() => const MedicalScreen());
      case 'assignment':
        final id = int.tryParse(notice.ref ?? '');
        Get.to(() => id == null
            ? const AssignmentsScreen()
            : AssignmentDetailScreen(assignmentId: id));
      case 'payslip_q':
        final id = int.tryParse(notice.ref ?? '');
        Get.to(() => id == null
            ? const PayslipQuestionsScreen()
            : PayslipQuestionDetailScreen(questionId: id));
      case 'purchase':
        final id = int.tryParse(notice.ref ?? '');
        Get.to(() => id == null
            ? const PurchasesScreen()
            : PurchaseDetailScreen(purchaseId: id));
    }
  }

  /// Вкладка оболочки: экран оповещений открыт поверх неё, сворачиваем.
  void _toTab(int index) {
    ShellTab.open(index);
    Get.until((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: Text('notices'.tr,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final feed = _feed;
    if (_loading && feed == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (feed == null) {
      return LoadErrorView(problem: _problem, onRetry: _load);
    }
    if (feed.items.isEmpty && feed.system.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: Dimensions.height30 * 3),
            Icon(Icons.notifications_none, size: 56, color: context.mutedColor),
            const SizedBox(height: 12),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Dimensions.width20),
              child: Text('notices_empty'.tr,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.mutedColor)),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(vertical: Dimensions.height30 / 3),
        children: [
          if (feed.system.isNotEmpty) ...[
            _sectionTitle('notices_system'.tr),
            for (final problem in feed.system) _problemCard(problem),
            if (feed.items.isNotEmpty) _sectionTitle('notices'.tr),
          ],
          for (final notice in feed.items) _noticeCard(notice),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding:
            EdgeInsets.fromLTRB(Dimensions.width20, 12, Dimensions.width20, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.mutedColor)),
      );

  Widget _problemCard(SystemProblem problem) {
    final color = Colors.orange.shade800;
    return _card(
      icon: Icons.warning_amber_rounded,
      color: color,
      title: problem.title,
      body: problem.body,
      highlighted: true,
      onTap: () => Get.to(() => const RolloutScreen()),
    );
  }

  Widget _noticeCard(AppNotice notice) {
    final (icon, color) = switch (notice.kind) {
      'payslip' => (Icons.receipt_long, context.accentColor),
      'menu' => (Icons.restaurant_menu, const Color(0xFFC62828)),
      'queue' => (Icons.pending_actions, const Color(0xFF4527A0)),
      'it' => (Icons.support_agent, const Color(0xFF37474F)),
      'purchase' => (Icons.shopping_cart_outlined, const Color(0xFFAD1457)),
      'payslip_q' => (Icons.contact_support_outlined, context.accentColor),
      'assignment' => (Icons.task_alt, const Color(0xFF0277BD)),
      'medical' => (Icons.health_and_safety_outlined, const Color(0xFF00838F)),
      'outage' => (Icons.power_off_outlined, const Color(0xFFE65100)),
      'itasset' => (Icons.devices_outlined, const Color(0xFF00695C)),
      'reception' => (Icons.event_seat_outlined, const Color(0xFF5D4037)),
      'trip' => (Icons.flight_takeoff, const Color(0xFF0277BD)),
      _ => (Icons.campaign_outlined, const Color(0xFF1565C0)),
    };
    return _card(
      icon: icon,
      color: color,
      title: notice.title,
      body: notice.body,
      when: _when(notice.createdAt),
      highlighted: notice.unread,
      onTap: () => _open(notice),
    );
  }

  Widget _card({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    String when = '',
    bool highlighted = false,
    VoidCallback? onTap,
  }) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 5),
      decoration: BoxDecoration(
        color: highlighted
            ? Color.alphaBlend(color.withOpacity(0.08), context.cardSurface)
            : context.cardSurface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: context.cardShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: color.withOpacity(0.14),
                child: Icon(icon, size: 20, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(title,
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: highlighted
                                      ? FontWeight.w700
                                      : FontWeight.w600)),
                        ),
                        if (when.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(when,
                              style: TextStyle(
                                  fontSize: 12, color: context.mutedColor)),
                        ],
                      ],
                    ),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(body,
                          style:
                              TextStyle(fontSize: 13, color: context.inkColor)),
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

  String _when(DateTime? moment) {
    if (moment == null) return '';
    final local = moment.toLocal();
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(local.year, local.month, local.day))
        .inDays;
    if (days == 0) return DateFormat('HH:mm').format(local);
    if (days == 1) return 'yesterday'.tr;
    return DateFormat('dd.MM.yyyy').format(local);
  }
}
