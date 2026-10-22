import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart' show AssignPerson;
import '../requests/onboarding_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';
import '../widgets/person_picker_dialog.dart';
import 'onboarding_screen.dart';

/// План адаптации: что готово, куда идти, кто отмечает.
class OnboardingDetailScreen extends StatefulWidget {
  const OnboardingDetailScreen({Key? key, required this.onboardingId})
      : super(key: key);

  final int onboardingId;

  @override
  State<OnboardingDetailScreen> createState() => _OnboardingDetailScreenState();
}

class _OnboardingDetailScreenState extends State<OnboardingDetailScreen> {
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  Onboarding? _item;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final item = await fetchOnboarding(widget.onboardingId);
      if (!mounted) return;
      setState(() {
        _item = item;
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

  Future<void> _apply(Future<OnboardingResult> call) async {
    setState(() => _busy = true);
    final result = await call;
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      setState(() => _item = result.item);
      return;
    }
    final key = 'ob_err_${result.error}';
    _show(result.error != null && key.tr != key ? key.tr : 'it_err_failed'.tr);
  }

  Future<bool> _confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(text),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('cancel'.tr)),
            TextButton(
                key: const Key('ob_confirm'),
                onPressed: () => Navigator.pop(context, true),
                child: Text('ob_yes'.tr)),
          ],
        ),
      ) ==
      true;

  Future<void> _toggle(Onboarding item, OnboardingStep step) async {
    if (step.done) {
      if (!await _confirm('ob_undo_confirm'.tr) || !mounted) return;
      await _apply(markOnboardingStep(item.id, step.step, false));
      return;
    }
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'ob_step_${step.step}'.tr,
        fields: [DialogField('note', 'ob_mark_note'.tr)],
        okLabel: 'ob_mark'.tr,
      ),
    );
    if (values == null || !mounted) return;
    await _apply(markOnboardingStep(item.id, step.step, true,
        note: (values['note'] ?? '').trim()));
  }

  Future<void> _changeMentor(Onboarding item) async {
    final person = await showDialog<AssignPerson>(
        context: context,
        builder: (_) => PersonPickerDialog(
            title: 'ob_mentor'.tr, search: searchOnboardingPeople));
    if (person == null || !mounted) return;
    await _apply(changeOnboardingMentor(item.id, person.id));
  }

  Future<void> _cancel(Onboarding item) async {
    if (!await _confirm('ob_cancel_confirm'.tr) || !mounted) return;
    await _apply(cancelOnboarding(item.id));
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: item == null || item.isMine
                ? 'ob_title'.tr
                : item.employee?.name ?? 'ob_title'.tr,
            color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null || item == null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : _body(item),
    );
  }

  Widget _body(Onboarding item) {
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    final total = item.steps.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                    'ob_start'
                        .trParams({'date': onboardingDate(item.startDate)}),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              OnboardingStatusChip(status: item.status),
            ],
          ),
        ),
        if (!item.isMine && item.employee != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
            child: Text(
                [item.employee!.jobTitle, item.employee!.department]
                    .where((s) => s.isNotEmpty)
                    .join(' · '),
                style: muted),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: LinearProgressIndicator(
              value: total == 0 ? 0 : item.doneCount / total,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          child: Text(
              'ob_progress'
                  .trParams({'done': '${item.doneCount}', 'total': '$total'}),
              key: const Key('ob_progress'),
              style: muted),
        ),
        ListTile(
          leading: const Icon(Icons.support_agent_outlined),
          title: Text(item.mentor?.name ?? 'ob_no_mentor'.tr),
          subtitle: Text([
            'ob_mentor'.tr,
            if ((item.mentor?.jobTitle ?? '').isNotEmpty) item.mentor!.jobTitle,
          ].join(' · ')),
          trailing: item.canManage
              ? IconButton(
                  key: const Key('ob_change_mentor'),
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'ob_change_mentor'.tr,
                  onPressed: _busy ? null : () => _changeMentor(item),
                )
              : null,
        ),
        if (item.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(item.note),
          ),
        const Divider(height: 1),
        for (final step in item.steps) _step(item, step),
        if (item.canManage)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: OutlinedButton.icon(
              key: const Key('ob_cancel'),
              onPressed: _busy ? null : () => _cancel(item),
              icon: const Icon(Icons.close),
              label: Text('ob_cancel'.tr),
            ),
          ),
      ],
    );
  }

  Widget _step(Onboarding item, OnboardingStep step) {
    final doneAt = step.doneAt;
    final lines = <String>[
      if (step.done)
        'ob_done_by'.trParams({
          'who': step.doneBy?.name ?? '',
          'date':
              doneAt == null ? '' : DateFormat('dd.MM HH:mm').format(doneAt),
        })
      else
        'ob_hint_${step.step}'.tr,
      if (step.note.isNotEmpty) step.note,
    ];
    return CheckboxListTile(
      key: Key('ob_mark_${step.step}'),
      value: step.done,
      controlAffinity: ListTileControlAffinity.leading,
      onChanged: step.canMark && !_busy ? (_) => _toggle(item, step) : null,
      title: Text('ob_step_${step.step}'.tr,
          style: TextStyle(
              decoration: step.done ? TextDecoration.lineThrough : null)),
      subtitle: Text(lines.join('\n')),
    );
  }
}
