import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart' show AssignPerson;
import '../requests/onboarding_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import '../widgets/person_picker_dialog.dart';
import 'onboarding_detail_screen.dart';

String onboardingDate(DateTime? day) =>
    day == null ? '' : DateFormat('dd.MM.yyyy').format(day);

/// Мой план адаптации, новички, у которых есть мой пункт, а у кадров — все.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({Key? key}) : super(key: key);

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  OnboardingList _data = const OnboardingList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await fetchOnboardings();
      if (!mounted) return;
      setState(() {
        _data = data;
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

  Future<void> _open(Onboarding item) async {
    await Get.to(() => OnboardingDetailScreen(onboardingId: item.id));
    if (mounted) _load();
  }

  Future<void> _create() async {
    final created =
        await Get.to<Onboarding?>(() => const OnboardingFormScreen());
    if (created != null && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final mine = _data.mine;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'ob_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: _data.hr
          ? FloatingActionButton.extended(
              key: const Key('ob_new'),
              onPressed: _loading ? null : _create,
              icon: const Icon(Icons.person_add_alt),
              label: Text('ob_new'.tr),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(top: 8, bottom: 96),
                    children: [
                      if (mine != null) ...[
                        _heading('ob_mine'.tr),
                        _card(mine, mine: true),
                      ],
                      if (_data.items.isNotEmpty) ...[
                        _heading('ob_newcomers'.tr),
                        for (final item in _data.items) _card(item),
                      ],
                      if (mine == null && _data.items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text('ob_empty'.tr,
                              key: const Key('ob_empty'),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: context.mutedColor)),
                        ),
                    ],
                  ),
                ),
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
        child: Text(text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      );

  Widget _card(Onboarding item, {bool mine = false}) {
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    final total = item.steps.length;
    return InkWell(
      key: Key('ob_item_${item.id}'),
      onTap: () => _open(item),
      child: Container(
        margin:
            EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 5),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.cardSurface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: context.cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                      mine
                          ? 'ob_start'.trParams(
                              {'date': onboardingDate(item.startDate)})
                          : item.employee?.name ?? '',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                OnboardingStatusChip(status: item.status),
              ],
            ),
            if (!mine) ...[
              const SizedBox(height: 2),
              Text(
                  [
                    item.employee?.jobTitle ?? '',
                    'ob_start'
                        .trParams({'date': onboardingDate(item.startDate)}),
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: muted),
            ],
            const SizedBox(height: 8),
            LinearProgressIndicator(
                value: total == 0 ? 0 : item.doneCount / total,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3)),
            const SizedBox(height: 4),
            Text(
                'ob_progress'
                    .trParams({'done': '${item.doneCount}', 'total': '$total'}),
                style: muted),
          ],
        ),
      ),
    );
  }
}

class OnboardingStatusChip extends StatelessWidget {
  const OnboardingStatusChip({Key? key, required this.status})
      : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(switch (status) {
      'done' => const Color(0xFF2E7D32),
      'cancelled' => const Color(0xFF757575),
      _ => const Color(0xFF1565C0),
    });
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('ob_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Кадрам: завести план на нового сотрудника.
class OnboardingFormScreen extends StatefulWidget {
  const OnboardingFormScreen({Key? key, this.now}) : super(key: key);

  final DateTime? now;

  @override
  State<OnboardingFormScreen> createState() => _OnboardingFormScreenState();
}

class _OnboardingFormScreenState extends State<OnboardingFormScreen> {
  final _note = TextEditingController();
  AssignPerson? _newcomer;
  AssignPerson? _mentor;
  late DateTime _start;
  final Set<String> _steps = {...onboardingSteps};
  bool _saving = false;

  DateTime get _today {
    final now = widget.now ?? DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    _start = _today;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _show(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<AssignPerson?> _pick(String title) => showDialog<AssignPerson>(
      context: context,
      builder: (_) =>
          PersonPickerDialog(title: title, search: searchOnboardingPeople));

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _start,
      firstDate: _today.subtract(const Duration(days: 30)),
      lastDate: _today.add(const Duration(days: 60)),
    );
    if (picked != null && mounted) setState(() => _start = picked);
  }

  Future<void> _save() async {
    final newcomer = _newcomer;
    if (newcomer == null) {
      _show('ob_pick_newcomer'.tr);
      return;
    }
    if (_steps.isEmpty) {
      _show('ob_err_bad_steps'.tr);
      return;
    }
    if (_steps.contains('mentor') && _mentor == null) {
      _show('ob_err_mentor_required'.tr);
      return;
    }
    setState(() => _saving = true);
    final result = await createOnboarding(
      employeeId: newcomer.id,
      startDate: _start,
      mentorId: _mentor?.id,
      steps: [
        for (final s in onboardingSteps)
          if (_steps.contains(s)) s
      ],
      note: _note.text.trim(),
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!result.ok) {
      final key = 'ob_err_${result.error}';
      _show(
          result.error != null && key.tr != key ? key.tr : 'it_err_failed'.tr);
      return;
    }
    Get.back(result: result.item);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(title: BigText(content: 'ob_new'.tr, color: Colors.white)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          ListTile(
            key: const Key('ob_newcomer'),
            leading: const Icon(Icons.person_outline),
            title: Text(_newcomer?.name ?? 'ob_pick_newcomer'.tr),
            subtitle: Text(_newcomer?.jobTitle ?? 'ob_newcomer'.tr),
            onTap: () async {
              final person = await _pick('ob_newcomer'.tr);
              if (person != null && mounted) {
                setState(() => _newcomer = person);
              }
            },
          ),
          ListTile(
            key: const Key('ob_start'),
            leading: const Icon(Icons.event_outlined),
            title: Text('ob_start'.trParams({'date': onboardingDate(_start)})),
            onTap: _pickDate,
          ),
          ListTile(
            key: const Key('ob_mentor'),
            leading: const Icon(Icons.support_agent_outlined),
            title: Text(_mentor?.name ?? 'ob_no_mentor'.tr),
            subtitle: Text('ob_mentor'.tr),
            onTap: () async {
              final person = await _pick('ob_mentor'.tr);
              if (person != null && mounted) setState(() => _mentor = person);
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('ob_steps'.tr,
                style:
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          for (final step in onboardingSteps)
            CheckboxListTile(
              key: Key('ob_step_$step'),
              value: _steps.contains(step),
              title: Text('ob_step_$step'.tr),
              subtitle: Text('ob_hint_$step'.tr),
              onChanged: (on) => setState(
                  () => on == true ? _steps.add(step) : _steps.remove(step)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: TextField(
              key: const Key('ob_note'),
              controller: _note,
              maxLength: 500,
              maxLines: 3,
              minLines: 1,
              decoration: InputDecoration(
                  labelText: 'ob_note'.tr,
                  border: const OutlineInputBorder(),
                  counterText: ''),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                key: const Key('ob_create'),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.check),
                label: Text('ob_create'.tr),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
