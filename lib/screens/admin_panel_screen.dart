import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../utils/desktop.dart';

import '../requests/admin_request.dart';
import '../requests/account_request.dart';
import '../utils/colors.dart';
import '../utils/initials.dart';
import '../utils/dimensions.dart';
import '../utils/search_fold.dart';
import '../widgets/app_drawer.dart';
import '../widgets/custom_text.dart';
import '../widgets/skeleton.dart';
import 'admin_employee_screen.dart';
import 'rollout_screen.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/load_error_view.dart';

/// Staff directory for the system administrator: search anyone, open their
/// turnstile report, payslips and leave.
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({Key? key}) : super(key: key);

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  final _searchController = TextEditingController();

  List<AdminEmployee> _all = [];
  bool _loading = true;
  bool _error = false;
  LoadProblem? _problem;
  String _query = '';
  String? _department; // null = all departments
  bool _onlyWithLogin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final rows = await fetchAllEmployees();
      if (!mounted) return;
      setState(() {
        _all = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
        _problem = problemOfAny(e);
      });
    }
  }

  List<String> get _departments {
    final names = _all
        .map((e) => e.department)
        .where((d) => d.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    return names;
  }

  List<AdminEmployee> get _filtered {
    final q = _query.trim().toLowerCase();
    return _all.where((e) {
      if (_onlyWithLogin && !e.hasLogin) return false;
      if (_department != null && e.department != _department) return false;
      if (q.isEmpty) return true;
      // Раскладка значения не имеет: «Аскаров» находит «Асқаров».
      return matchesQuery(e.fullName, q) ||
          matchesQuery(e.jobTitle, q) ||
          e.employeeId.toLowerCase().contains(q) ||
          e.login.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Scaffold(
      backgroundColor: context.pageColor,
      drawer: sidebarShown(context) ? null : const AppDrawer(),
      appBar: AppBar(
        leading: sidebarShown(context)
            ? null
            : Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: BigText(content: 'admin_panel'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.system_update_outlined),
            tooltip: 'rollout_title'.tr,
            onPressed: () => Get.to(() => const RolloutScreen()),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSearchBar(),
          if (!_loading && !_error) _buildFilters(),
          Expanded(
            child: _loading
                ? const SkeletonList(rows: 8, hasLeading: true)
                : _error
                    ? _buildError()
                    : list.isEmpty
                        ? _buildEmpty()
                        : RefreshIndicator(
                            color: context.accentColor,
                            onRefresh: _load,
                            child: ListView.builder(
                              itemCount: list.length,
                              itemBuilder: (_, i) => _buildTile(list[i]),
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: AppColors.mainColor,
      padding: EdgeInsets.fromLTRB(
          Dimensions.width20, 0, Dimensions.width20, Dimensions.height30 * 0.4),
      child: TextField(
        controller: _searchController,
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: 'admin_search_hint'.tr,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: context.cardSurface,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      color: context.cardSurface,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: Dimensions.width20),
              children: [
                _chip(
                  label: 'admin_all_departments'.tr,
                  selected: _department == null,
                  onTap: () => setState(() => _department = null),
                ),
                ..._departments.map((d) => _chip(
                      label: d,
                      selected: _department == d,
                      onTap: () => setState(() => _department = d),
                    )),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(left: Dimensions.width20, right: 8, top: 4),
            child: Row(
              children: [
                Text(
                  '${'admin_found'.tr}: ${_filtered.length}',
                  style: TextStyle(fontSize: 12, color: context.mutedColor),
                ),
                const Spacer(),
                Text('admin_only_with_login'.tr,
                    style: TextStyle(fontSize: 12, color: context.mutedColor)),
                Switch(
                  value: _onlyWithLogin,
                  activeColor: AppColors.mainColor,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => setState(() => _onlyWithLogin = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _buildTile(AdminEmployee e) {
    final initials = initialsOf(e.fullName);
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          leading: CircleAvatar(
            backgroundColor: e.hasLogin
                ? AppColors.mainColor.withOpacity(0.15)
                : context.hairlineColor,
            child: Text(
              initials.toUpperCase(),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: e.hasLogin ? context.accentColor : context.mutedColor,
              ),
            ),
          ),
          title: Text(e.fullName, style: const TextStyle(fontSize: 13)),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.jobTitle,
                  style: TextStyle(fontSize: 12, color: context.mutedColor)),
              const SizedBox(height: 2),
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  if (e.hasLogin && e.loginActive)
                    _badge('${'login'.tr}: ${e.login}', AppColors.mainColor),
                  if (e.hasLogin && !e.loginActive)
                    _badge('account_disabled'.tr, AppColors.niceRed),
                  if (e.payslipCount > 0)
                    _badge('${'payslip'.tr}: ${e.payslipCount}',
                        Colors.blue.shade700),
                  if (e.accessCount > 0)
                    _badge('${'tab_turnstile'.tr}: ${e.accessCount}',
                        Colors.orange.shade800),
                ],
              ),
            ],
          ),
          isThreeLine: true,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Сбросить пароль можно только тому, у кого есть учётная запись.
              if (e.hasLogin && e.loginActive)
                IconButton(
                  icon: const Icon(Icons.lock_reset, size: 20),
                  tooltip: 'password_reset'.tr,
                  onPressed: () => _confirmReset(e),
                ),
              if (e.hasLogin)
                IconButton(
                  icon: Icon(e.loginActive ? Icons.person_off_outlined : Icons.person_add_alt,
                      size: 20),
                  tooltip: e.loginActive ? 'account_disable'.tr : 'account_enable'.tr,
                  onPressed: () => _confirmActive(e),
                ),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
          onTap: () => Get.to(() => AdminEmployeeScreen(employee: e)),
        ),
      ),
    );
  }

  /// Сброс пароля: временным становится одноразовый код, и при первом входе
  /// человека попросят придумать свой. Спрашиваем подтверждение — действие
  /// выкидывает человека со всех его устройств.
  Future<void> _confirmReset(AdminEmployee e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('password_reset'.tr),
        content: Text('password_reset_confirm'.trParams({'name': e.fullName})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('cancel'.tr),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('password_reset'.tr),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final (temporary, problem) = await resetPassword(e.login);
    if (!mounted) return;
    if (temporary == null) {
      final (title, hint) = problemTexts(problem);
      Get.snackbar(title, hint,
          snackPosition: SnackPosition.BOTTOM, margin: const EdgeInsets.all(12));
      return;
    }
    HapticFeedback.mediumImpact();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('password_reset_done'.tr),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('password_reset_tell'.trParams({'name': e.fullName})),
            const SizedBox(height: 12),
            SelectableText(
              temporary,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 2),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: temporary));
              Navigator.pop(ctx);
            },
            child: Text('copy'.tr),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Уволен — отключить учётную запись. Пропуска гаснут сразу, а сервер
  /// сообщает об этом конфиденциальному чату: там тоже гасятся сессии и
  /// уведомления. Включение обратно чат не трогает.
  Future<void> _confirmActive(AdminEmployee e) async {
    final disabling = e.loginActive;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(disabling ? 'account_disable'.tr : 'account_enable'.tr),
        content: Text((disabling ? 'account_disable_confirm' : 'account_enable_confirm')
            .trParams({'name': e.fullName})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('cancel'.tr),
          ),
          ElevatedButton(
            style: disabling
                ? ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700)
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(disabling ? 'account_disable'.tr : 'account_enable'.tr,
                style: disabling ? const TextStyle(color: Colors.white) : null),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final (done, chat, problem) = await setAccountActive(e.login, !disabling);
    if (!mounted) return;
    if (!done) {
      final (title, hint) = problemTexts(problem);
      Get.snackbar(title, hint,
          snackPosition: SnackPosition.BOTTOM, margin: const EdgeInsets.all(12));
      return;
    }
    HapticFeedback.mediumImpact();
    final chatNote = switch (chat) {
      'disabled' || 'already' => 'account_chat_disabled'.tr,
      'failed' => 'account_chat_failed'.tr,
      'privileged' => 'account_chat_privileged'.tr,
      _ => '',
    };
    Get.snackbar(
      disabling ? 'account_disabled_done'.tr : 'account_enabled_done'.tr,
      [e.fullName, if (chatNote.isNotEmpty) chatNote].join('\n'),
      snackPosition: SnackPosition.BOTTOM,
      margin: const EdgeInsets.all(12),
      duration: Duration(seconds: chat == 'failed' || chat == 'privileged' ? 8 : 4),
    );
    _load();
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 60, color: context.hairlineColor),
          SizedBox(height: Dimensions.height30 / 2),
          Text('no_records'.tr,
              style: TextStyle(color: context.mutedColor, fontSize: 15)),
        ],
      ),
    );
  }

  Widget _buildError() => LoadErrorView(problem: _problem, onRetry: _load);
}
