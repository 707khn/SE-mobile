import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart' show AssignPerson;
import '../requests/workwear_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';
import '../widgets/person_picker_dialog.dart';

String _date(DateTime? day) =>
    day == null ? '' : DateFormat('dd.MM.yyyy').format(day);

Color _dueColor(String due) => switch (due) {
      'overdue' => const Color(0xFFC62828),
      'soon' => const Color(0xFFE65100),
      _ => const Color(0xFF757575),
    };

String _errorText(WorkwearResult result) {
  final key = 'ww_err_${result.error}';
  return result.error != null && key.tr != key ? key.tr : 'it_err_failed'.tr;
}

/// Свои вещи и стирка; у хозотдела — ещё вкладка с очередью и сроками.
class WorkwearScreen extends StatefulWidget {
  const WorkwearScreen({Key? key}) : super(key: key);

  @override
  State<WorkwearScreen> createState() => _WorkwearScreenState();
}

class _WorkwearScreenState extends State<WorkwearScreen> {
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  WorkwearCard _mine = const WorkwearCard();
  WorkwearDesk? _desk;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchMyWorkwear();
      final desk = mine.staff ? await fetchWorkwearDesk() : null;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _desk = desk;
        _problem = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = problemOfAny(e);
        _loading = false;
      });
    }
  }

  void _show(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _run(Future<WorkwearResult> call, {String? done}) async {
    setState(() => _busy = true);
    final result = await call;
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok) {
      _show(_errorText(result));
      return;
    }
    _show(done ?? 'ww_saved'.tr);
    _load();
  }

  Future<AssignPerson?> _pickPerson(String title) => showDialog<AssignPerson>(
      context: context,
      builder: (_) =>
          PersonPickerDialog(title: title, search: searchWorkwearPeople));

  Future<void> _issue() async {
    final person = await _pickPerson('ww_issue'.tr);
    if (person == null || !mounted) return;
    final fields = await showWorkwearIssueDialog(context, person);
    if (fields == null || !mounted) return;
    await _run(issueWorkwear(person.id, fields));
  }

  Future<void> _accept() async {
    final person = await _pickPerson('ww_accept'.tr);
    if (person == null || !mounted) return;
    final kind = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(person.name),
        children: [
          for (final k in const ['wash', 'repair'])
            SimpleDialogOption(
              key: Key('ww_kind_$k'),
              onPressed: () => Navigator.pop(context, k),
              child: Text('ww_kind_$k'.tr),
            ),
        ],
      ),
    );
    if (kind == null || !mounted) return;
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'ww_kind_$kind'.tr,
        fields: [DialogField('items', 'ww_items'.tr, required: true)],
        okLabel: 'ww_accept'.tr,
      ),
    );
    if (values == null || !mounted) return;
    await _run(acceptLaundry(person.id, kind, values['items'] ?? ''));
  }

  Future<void> _openCard() async {
    final person = await _pickPerson('ww_card'.tr);
    if (person == null || !mounted) return;
    await Get.to(() => WorkwearCardScreen(employeeId: person.id));
    if (mounted) _load();
  }

  Future<void> _remind() async {
    setState(() => _busy = true);
    final result = await remindWorkwearDue();
    if (!mounted) return;
    setState(() => _busy = false);
    _show(result.ok
        ? 'ww_reminded'.trParams({'count': '${result.reminded ?? 0}'})
        : _errorText(result));
  }

  @override
  Widget build(BuildContext context) {
    final desk = _desk;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _problem != null
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : desk == null
                ? _mineView()
                : TabBarView(children: [_mineView(), _deskView(desk)]);
    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'ww_title'.tr, color: Colors.white),
        actions: [
          if (desk != null)
            IconButton(
              key: const Key('ww_card'),
              icon: const Icon(Icons.person_search_outlined),
              tooltip: 'ww_card'.tr,
              onPressed: _busy ? null : _openCard,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: desk == null
            ? null
            : TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: [
                  Tab(text: 'ww_tab_mine'.tr),
                  Tab(text: 'ww_tab_desk'.tr),
                ],
              ),
      ),
      body: body,
    );
    return desk == null
        ? scaffold
        : DefaultTabController(length: 2, child: scaffold);
  }

  Widget _mineView() {
    final mine = _mine;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          if (mine.laundry.isNotEmpty) ...[
            workwearHeading('ww_laundry'.tr),
            for (final row in mine.laundry) WorkwearLaundryTile(row: row),
          ],
          workwearHeading('ww_issued'.tr),
          if (mine.issues.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text('ww_empty'.tr,
                  key: const Key('ww_empty'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.mutedColor)),
            ),
          for (final issue in mine.issues) WorkwearIssueTile(issue: issue),
        ],
      ),
    );
  }

  Widget _deskView(WorkwearDesk desk) {
    final muted = TextStyle(color: context.mutedColor);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('ww_issue'),
                  onPressed: _busy ? null : _issue,
                  icon: const Icon(Icons.checkroom_outlined),
                  label: Text('ww_issue'.tr),
                ),
                OutlinedButton.icon(
                  key: const Key('ww_accept'),
                  onPressed: _busy ? null : _accept,
                  icon: const Icon(Icons.local_laundry_service_outlined),
                  label: Text('ww_accept'.tr),
                ),
              ],
            ),
          ),
          workwearHeading('ww_queue'.tr),
          if (desk.laundry.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('ww_queue_empty'.tr, style: muted),
            ),
          for (final row in desk.laundry)
            WorkwearLaundryTile(
              row: row,
              action: TextButton(
                key: Key('ww_laundry_${row.id}'),
                onPressed: _busy
                    ? null
                    : () => _run(laundryAction(row.id,
                        row.status == 'accepted' ? 'ready' : 'collected')),
                child: Text(row.status == 'accepted'
                    ? 'ww_ready'.tr
                    : 'ww_collected'.tr),
              ),
            ),
          workwearHeading('ww_due_list'.tr),
          if (desk.due.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('ww_due_empty'.tr, style: muted),
            )
          else ...[
            for (final issue in desk.due)
              WorkwearIssueTile(
                issue: issue,
                onTap: issue.employee == null
                    ? null
                    : () async {
                        await Get.to(() =>
                            WorkwearCardScreen(employeeId: issue.employee!.id));
                        if (mounted) _load();
                      },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: OutlinedButton.icon(
                key: const Key('ww_remind'),
                onPressed: _busy ? null : _remind,
                icon: const Icon(Icons.notifications_active_outlined),
                label: Text('ww_remind'.tr),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

Widget workwearHeading(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Text(text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
    );

/// Поля выдачи: наименование, размер, количество, срок носки.
Future<Map<String, String>?> showWorkwearIssueDialog(
        BuildContext context, AssignPerson person,
        {WorkwearIssue? like}) =>
    showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: person.name,
        fields: [
          DialogField('item', 'ww_item'.tr,
              required: true, initial: like?.item ?? ''),
          DialogField('size', 'ww_size_field'.tr, initial: like?.size ?? ''),
          DialogField('quantity', 'ww_quantity'.tr,
              number: true, required: true, initial: '${like?.quantity ?? 1}'),
          DialogField('wear_months', 'ww_months'.tr,
              number: true, initial: '${like?.wearMonths ?? ''}'),
        ],
        okLabel: 'ww_issue'.tr,
      ),
    );

class WorkwearIssueTile extends StatelessWidget {
  const WorkwearIssueTile(
      {Key? key, required this.issue, this.onTap, this.trailing})
      : super(key: key);

  final WorkwearIssue issue;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    final color = context.readable(_dueColor(issue.due));
    final details = [
      if (issue.employee != null) issue.employee!.name,
      if (issue.size.isNotEmpty) 'ww_size'.trParams({'size': issue.size}),
      if (issue.quantity > 1) '× ${issue.quantity}',
      'ww_issued_on'.trParams({'date': _date(issue.issuedOn)}),
    ];
    return InkWell(
      key: Key('ww_issue_${issue.id}'),
      onTap: onTap,
      child: Container(
        margin:
            EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.cardSurface,
          borderRadius: BorderRadius.circular(10),
          boxShadow: context.cardShadow,
          border: issue.due == 'overdue' || issue.due == 'soon'
              ? Border.all(color: color.withOpacity(0.6))
              : null,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(issue.item, style: const TextStyle(fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(details.join(' · '), style: muted),
                  const SizedBox(height: 2),
                  Text(
                      issue.dueOn == null
                          ? 'ww_due_none'.tr
                          : [
                              'ww_due_on'
                                  .trParams({'date': _date(issue.dueOn)}),
                              if (issue.due == 'soon' || issue.due == 'overdue')
                                'ww_due_${issue.due}'.tr,
                            ].join(' · '),
                      key: Key('ww_due_${issue.id}'),
                      style: TextStyle(
                          fontSize: 12,
                          color: color,
                          fontWeight: issue.due == 'ok' || issue.due == 'none'
                              ? FontWeight.normal
                              : FontWeight.w600)),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class WorkwearLaundryTile extends StatelessWidget {
  const WorkwearLaundryTile({Key? key, required this.row, this.action})
      : super(key: key);

  final WorkwearLaundry row;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    final ready = row.status == 'ready';
    final color =
        context.readable(ready ? const Color(0xFF2E7D32) : context.mutedColor);
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: ready ? Border.all(color: color.withOpacity(0.6)) : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.items, style: const TextStyle(fontSize: 15)),
                const SizedBox(height: 2),
                Text(
                    [
                      if (row.employee != null) row.employee!.name,
                      'ww_kind_${row.kind}'.tr,
                    ].join(' · '),
                    style: muted),
                Text('ww_status_${row.status}'.tr,
                    key: Key('ww_status_${row.id}'),
                    style: TextStyle(
                        fontSize: 12,
                        color: color,
                        fontWeight: ready ? FontWeight.w600 : null)),
              ],
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// Хозотделу: что числится за сотрудником — заменить, сдать, выдать ещё.
class WorkwearCardScreen extends StatefulWidget {
  const WorkwearCardScreen({Key? key, required this.employeeId})
      : super(key: key);

  final String employeeId;

  @override
  State<WorkwearCardScreen> createState() => _WorkwearCardScreenState();
}

class _WorkwearCardScreenState extends State<WorkwearCardScreen> {
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  WorkwearCard _card = const WorkwearCard();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final card = await fetchWorkwearCard(widget.employeeId);
      if (!mounted) return;
      setState(() {
        _card = card;
        _problem = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _problem = problemOfAny(e);
        _loading = false;
      });
    }
  }

  Future<void> _run(Future<WorkwearResult> call) async {
    setState(() => _busy = true);
    final result = await call;
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.ok ? 'ww_saved'.tr : _errorText(result))));
    if (result.ok) _load();
  }

  Future<void> _issue() async {
    final person = _card.employee ??
        AssignPerson(id: widget.employeeId, name: widget.employeeId);
    final fields = await showWorkwearIssueDialog(context, person);
    if (fields == null || !mounted) return;
    await _run(issueWorkwear(person.id, fields));
  }

  Future<void> _menu(WorkwearIssue issue) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('ww_replace'),
              leading: const Icon(Icons.autorenew),
              title: Text('ww_replace'.tr),
              onTap: () => Navigator.pop(context, 'replace'),
            ),
            ListTile(
              key: const Key('ww_return'),
              leading: const Icon(Icons.assignment_return_outlined),
              title: Text('ww_return'.tr),
              onTap: () => Navigator.pop(context, 'return'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    await _run(workwearIssueAction(issue.id, action));
  }

  @override
  Widget build(BuildContext context) {
    final employee = _card.employee;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: employee?.name ?? 'ww_card'.tr, color: Colors.white),
      ),
      floatingActionButton: _loading || _problem != null
          ? null
          : FloatingActionButton.extended(
              key: const Key('ww_card_issue'),
              onPressed: _busy ? null : _issue,
              icon: const Icon(Icons.checkroom_outlined),
              label: Text('ww_issue'.tr),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 96),
                  children: [
                    if (employee != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                        child: Text(
                            [employee.jobTitle, employee.department]
                                .where((s) => s.isNotEmpty)
                                .join(' · '),
                            style: TextStyle(color: context.mutedColor)),
                      ),
                    if (_card.laundry.isNotEmpty) ...[
                      workwearHeading('ww_laundry'.tr),
                      for (final row in _card.laundry)
                        WorkwearLaundryTile(row: row),
                    ],
                    workwearHeading('ww_issued'.tr),
                    for (final issue in _card.issues)
                      WorkwearIssueTile(
                          issue: issue,
                          onTap: _busy ? null : () => _menu(issue)),
                  ],
                ),
    );
  }
}
