import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/admin_notifications_request.dart';
import '../requests/admin_request.dart';
import '../utils/app_theme.dart';
import '../utils/colors.dart';
import '../utils/load_problem.dart';
import '../utils/search_fold.dart';
import '../widgets/load_error_view.dart';
import '../widgets/skeleton.dart';

/// Вкладка «Уведомления» в админ-панели.
///
/// Что сервер разослал, скольким людям, на сколько телефонов и в сколько
/// Telegram-чатов, и что не дошло. И то, что сервер нарочно не стал
/// рассылать: повторная загрузка меню на тот же день уведомления не шлёт —
/// раньше это выглядело как поломка. Отсюда же — разослать вручную.
class AdminNotificationsTab extends StatefulWidget {
  const AdminNotificationsTab({Key? key}) : super(key: key);

  @override
  State<AdminNotificationsTab> createState() => AdminNotificationsTabState();
}

class AdminNotificationsTabState extends State<AdminNotificationsTab>
    with AutomaticKeepAliveClientMixin {
  PushLogReport? _report;
  bool _loading = true;
  LoadProblem? _problem;
  bool _failed = false;
  String? _kind; // null — все поводы
  bool _busy = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final report = await fetchPushLog();
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _problem = problemOfAny(e);
      });
    }
  }

  static String kindLabel(String kind) => switch (kind) {
        'menu' => 'an_kind_menu'.tr,
        'payslip' => 'an_kind_payslip'.tr,
        'news' => 'an_kind_news'.tr,
        'turnstile' => 'an_kind_turnstile'.tr,
        'general' => 'an_kind_general'.tr,
        _ => kind,
      };

  static (IconData, Color) _kindLook(String kind) => switch (kind) {
        'menu' => (Icons.restaurant_menu, const Color(0xFFC62828)),
        'payslip' => (Icons.receipt_long, AppColors.mainColor),
        'news' => (Icons.campaign_outlined, const Color(0xFF1565C0)),
        'turnstile' => (Icons.sensor_door_outlined, const Color(0xFFE65100)),
        _ => (Icons.notifications_outlined, const Color(0xFF4527A0)),
      };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading && _report == null) {
      return const SkeletonList(rows: 8, hasLeading: true);
    }
    if (_failed && _report == null) {
      return LoadErrorView(problem: _problem, onRetry: reload);
    }
    final report = _report!;
    final items = _kind == null
        ? report.items
        : report.items.where((e) => e.kind == _kind).toList();
    return RefreshIndicator(
      color: context.accentColor,
      onRefresh: reload,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _statusCard(report),
          _actions(),
          if (report.kinds.length > 1) _filters(report.kinds),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Text('an_empty'.tr,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.mutedColor)),
            ),
          ...items.map(_entryCard),
        ],
      ),
    );
  }

  Widget _statusCard(PushLogReport r) {
    Widget line(IconData icon, bool ok, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18,
                  color: ok ? AppColors.mainColor : AppColors.niceRed),
              const SizedBox(width: 8),
              Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
            ],
          ),
        );
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line(
            Icons.phone_android,
            r.pushEnabled,
            r.pushEnabled
                ? 'an_push_on'.trParams({
                    'people': '${r.pushPeople}',
                    'devices': '${r.pushDevices}',
                  })
                : (r.pushProblem.isEmpty ? 'an_push_off'.tr : r.pushProblem),
          ),
          line(
            Icons.telegram,
            r.telegramEnabled,
            r.telegramEnabled
                ? 'an_telegram_on'.trParams({'people': '${r.telegramPeople}'})
                : 'an_telegram_off'.tr,
          ),
        ],
      ),
    );
  }

  Widget _actions() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _sendMenu,
            icon: const Icon(Icons.restaurant_menu, size: 18),
            label: Text('an_send_menu'.tr),
          ),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _compose,
            icon: const Icon(Icons.edit_notifications_outlined, size: 18),
            label: Text('an_compose'.tr),
          ),
        ],
      ),
    );
  }

  Widget _filters(List<String> kinds) {
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text('an_kind_all'.tr),
              selected: _kind == null,
              onSelected: (_) => setState(() => _kind = null),
            ),
          ),
          ...kinds.map((k) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(kindLabel(k)),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
              )),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.cardSurface,
          borderRadius: BorderRadius.circular(10),
          boxShadow: context.cardShadow,
        ),
        child: child,
      );

  Widget _statusBadge(PushLogEntry e) {
    final (text, color) = switch (e.status) {
      'skipped' => ('an_status_skipped'.tr, const Color(0xFF8D6E63)),
      'error' => ('an_status_error'.tr, AppColors.niceRed),
      _ => ('an_status_sent'.tr, AppColors.mainColor),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  String _who(PushLogEntry e) {
    if (e.audience == 'all') return 'an_to_all'.tr;
    final names = e.recipients.join(', ');
    final more = e.people - e.recipients.length;
    return more > 0
        ? 'an_to_people_more'.trParams({'names': names, 'more': '$more'})
        : names;
  }

  Widget _entryCard(PushLogEntry e) {
    final (icon, color) = _kindLook(e.kind);
    final when = e.createdAt == null
        ? ''
        : DateFormat('dd.MM.yyyy HH:mm').format(e.createdAt!);
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    final stats = <String>[
      'an_people'.trParams({'count': '${e.people}'}),
      if (e.devices > 0)
        'an_devices'.trParams(
            {'delivered': '${e.delivered}', 'devices': '${e.devices}'}),
      if (e.telegram > 0) 'an_telegram'.trParams({'count': '${e.telegram}'}),
    ];
    return _card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withOpacity(0.12),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(e.title,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    _statusBadge(e),
                  ],
                ),
                if (e.body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(e.body, style: const TextStyle(fontSize: 13)),
                ],
                const SizedBox(height: 4),
                Text(
                    [
                      when,
                      e.source == 'manual'
                          ? 'an_manual'.trParams({'name': e.sentBy})
                          : 'an_auto'.tr,
                    ].where((s) => s.isNotEmpty).join(' · '),
                    style: muted),
                if (e.status != 'skipped') ...[
                  Text('${_who(e)} · ${stats.join(' · ')}', style: muted),
                ],
                if (e.note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(e.note,
                      style: TextStyle(
                          fontSize: 12,
                          color: e.status == 'error'
                              ? AppColors.niceRed
                              : context.inkColor.withOpacity(0.75))),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.replay, size: 20),
            tooltip: 'an_resend'.tr,
            onPressed: _busy ? null : () => _resend(e),
          ),
        ],
      ),
    );
  }

  // ── Отправка ──────────────────────────────────────────────────────────────

  Future<bool> _confirm(String title, String text, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('cancel'.tr)),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _run(Future<SendResult> Function() send) async {
    setState(() => _busy = true);
    final result = await send();
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.entry == null) {
      final String title;
      final String hint;
      if (result.error == 'no_menu') {
        title = 'an_no_menu'.tr;
        hint = 'an_no_menu_hint'.tr;
      } else {
        (title, hint) = problemTexts(result.problem);
      }
      Get.snackbar(title, hint,
          snackPosition: SnackPosition.BOTTOM,
          margin: const EdgeInsets.all(12));
      return;
    }
    HapticFeedback.mediumImpact();
    final e = result.entry!;
    Get.snackbar(
      e.status == 'error' ? 'an_status_error'.tr : 'an_sent_done'.tr,
      e.status == 'error' && e.note.isNotEmpty
          ? e.note
          : [
              'an_people'.trParams({'count': '${e.people}'}),
              'an_devices'.trParams(
                  {'delivered': '${e.delivered}', 'devices': '${e.devices}'}),
              'an_telegram'.trParams({'count': '${e.telegram}'}),
            ].join(' · '),
      snackPosition: SnackPosition.BOTTOM,
      margin: const EdgeInsets.all(12),
      duration: const Duration(seconds: 6),
    );
    reload();
  }

  Future<void> _sendMenu() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 30)),
      helpText: 'an_menu_pick_date'.tr,
    );
    if (day == null || !mounted) return;
    final label = DateFormat('dd.MM.yyyy').format(day);
    final ok = await _confirm('an_send_menu'.tr,
        'an_menu_confirm'.trParams({'date': label}), 'an_send'.tr);
    if (!ok) return;
    await _run(() => sendMenuNotice(day));
  }

  Future<void> _resend(PushLogEntry e) async {
    final who = e.audience == 'all'
        ? 'an_to_all'.tr
        : 'an_people'.trParams({'count': '${e.people}'});
    final ok = await _confirm('an_resend'.tr,
        'an_resend_confirm'.trParams({'title': e.title, 'who': who}),
        'an_send'.tr);
    if (!ok) return;
    await _run(() => resendPush(e.id));
  }

  Future<void> _compose() async {
    final draft = await showDialog<_Draft>(
      context: context,
      builder: (_) => const _ComposeDialog(),
    );
    if (draft == null || !mounted) return;
    await _run(() => sendCustomNotice(
          title: draft.title,
          body: draft.body,
          employeeIds: draft.people.map((p) => p.employeeId).toList(),
          feed: draft.feed,
        ));
  }
}

class _Draft {
  const _Draft(this.title, this.body, this.people, this.feed);
  final String title;
  final String body;
  final List<AdminEmployee> people;
  final bool feed;
}

/// Своё уведомление: текст, кому, класть ли в ленту под колокольчиком.
class _ComposeDialog extends StatefulWidget {
  const _ComposeDialog();

  @override
  State<_ComposeDialog> createState() => _ComposeDialogState();
}

class _ComposeDialogState extends State<_ComposeDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _everyone = true;
  bool _feed = true;
  final List<AdminEmployee> _people = [];

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _ready =>
      _title.text.trim().isNotEmpty && (_everyone || _people.isNotEmpty);

  Future<void> _pick() async {
    final chosen = await showDialog<AdminEmployee>(
      context: context,
      builder: (_) => const _EmployeePicker(),
    );
    if (chosen == null) return;
    if (_people.any((p) => p.employeeId == chosen.employeeId)) return;
    setState(() => _people.add(chosen));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('an_compose'.tr),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _title,
                maxLength: 200,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(labelText: 'an_field_title'.tr),
              ),
              TextField(
                controller: _body,
                maxLength: 500,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(labelText: 'an_field_body'.tr),
              ),
              Text('an_privacy'.tr,
                  style: TextStyle(fontSize: 12, color: context.mutedColor)),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: [
                  ButtonSegment(value: true, label: Text('an_to_all'.tr)),
                  ButtonSegment(value: false, label: Text('an_to_chosen'.tr)),
                ],
                selected: {_everyone},
                onSelectionChanged: (s) => setState(() => _everyone = s.first),
              ),
              if (!_everyone) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    ..._people.map((p) => InputChip(
                          label: Text(p.fullName),
                          onDeleted: () => setState(() => _people.remove(p)),
                        )),
                    ActionChip(
                      avatar: const Icon(Icons.person_add_alt, size: 18),
                      label: Text('an_add_person'.tr),
                      onPressed: _pick,
                    ),
                  ],
                ),
              ],
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _feed,
                onChanged: (v) => setState(() => _feed = v ?? true),
                title: Text('an_feed'.tr, style: const TextStyle(fontSize: 13)),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
        ElevatedButton(
          onPressed: _ready
              ? () => Navigator.pop(
                    context,
                    _Draft(_title.text.trim(), _body.text.trim(),
                        _everyone ? const [] : List.of(_people), _feed),
                  )
              : null,
          child: Text('an_send'.tr),
        ),
      ],
    );
  }
}

/// Поиск сотрудника по ФИО или табельному — для «Выбранным».
class _EmployeePicker extends StatefulWidget {
  const _EmployeePicker();

  @override
  State<_EmployeePicker> createState() => _EmployeePickerState();
}

class _EmployeePickerState extends State<_EmployeePicker> {
  List<AdminEmployee>? _all;
  String _query = '';
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    fetchAllEmployees().then((rows) {
      if (mounted) setState(() => _all = rows);
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final rows = (_all ?? const <AdminEmployee>[])
        .where((e) =>
            q.isEmpty ||
            matchesQuery(e.fullName, q) ||
            e.employeeId.toLowerCase().contains(q) ||
            e.login.toLowerCase().contains(q))
        .take(50)
        .toList();
    return AlertDialog(
      title: Text('an_add_person'.tr),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'admin_search_hint'.tr,
                prefixIcon: const Icon(Icons.search, size: 20),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _failed
                  ? Center(child: Text(problemTexts(null).$1))
                  : _all == null
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.builder(
                          itemCount: rows.length,
                          itemBuilder: (_, i) => ListTile(
                            dense: true,
                            title: Text(rows[i].fullName),
                            subtitle: Text(
                                '${rows[i].employeeId} · ${rows[i].jobTitle}'),
                            onTap: () => Navigator.pop(context, rows[i]),
                          ),
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
      ],
    );
  }
}
