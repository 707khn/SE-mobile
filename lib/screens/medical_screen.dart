import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart' show AssignPerson;
import '../requests/medical_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';
import '../widgets/person_picker_dialog.dart';

String _date(DateTime? day) =>
    day == null ? '' : DateFormat('dd.MM.yyyy').format(day);

String _time(DateTime? moment) =>
    moment == null ? '' : DateFormat('HH:mm').format(moment);

String _errorText(MedicalResult result) {
  final key = 'md_err_${result.error}';
  return result.error != null && key.tr != key ? key.tr : 'it_err_failed'.tr;
}

Color _stateColor(String state) => switch (state) {
      'overdue' => const Color(0xFFC62828),
      'soon' => const Color(0xFFE65100),
      _ => const Color(0xFF2E7D32),
    };

/// Свои сроки и запись в медпункт; у медпункта — приём дня и сроки.
class MedicalScreen extends StatefulWidget {
  const MedicalScreen({Key? key, this.today}) : super(key: key);

  /// Для проверок: какой сегодня день у вкладки медпункта.
  final DateTime? today;

  @override
  State<MedicalScreen> createState() => _MedicalScreenState();
}

class _MedicalScreenState extends State<MedicalScreen> {
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  MedicalMine _mine = const MedicalMine();
  MedicalDesk? _desk;
  late DateTime _day;

  @override
  void initState() {
    super.initState();
    final now = widget.today ?? DateTime.now();
    _day = DateTime(now.year, now.month, now.day);
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchMyMedical();
      final desk = mine.medic ? await fetchMedicalDesk(_day) : null;
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

  Future<void> _run(Future<MedicalResult> call,
      {String Function(MedicalResult)? done}) async {
    setState(() => _busy = true);
    final result = await call;
    if (!mounted) return;
    setState(() => _busy = false);
    _show(
        result.ok ? (done?.call(result) ?? 'md_saved'.tr) : _errorText(result));
    if (result.ok) _load();
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
                key: const Key('md_confirm'),
                onPressed: () => Navigator.pop(context, true),
                child: Text('md_yes'.tr)),
          ],
        ),
      ) ==
      true;

  Future<void> _book(MedicalSlot slot) async {
    final ok = await _confirm('md_book_confirm'.trParams(
        {'date': _date(slot.startsAt), 'time': _time(slot.startsAt)}));
    if (!ok || !mounted) return;
    await _run(bookMedicalSlot(slot.id), done: (_) => 'md_booked'.tr);
  }

  Future<void> _cancel(MedicalSlot slot) async {
    if (!await _confirm('${'md_cancel'.tr}?') || !mounted) return;
    await _run(cancelMedicalSlot(slot.id), done: (_) => 'md_cancelled'.tr);
  }

  Future<void> _shiftDay(int days) async {
    setState(() => _day = _day.add(Duration(days: days)));
    await _load();
  }

  Future<String?> _pickKind(List<String> kinds, String prefix) =>
      showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          children: [
            for (final k in kinds)
              SimpleDialogOption(
                key: Key('md_kind_$k'),
                onPressed: () => Navigator.pop(context, k),
                child: Text('$prefix$k'.tr),
              ),
          ],
        ),
      );

  Future<void> _openSlots() async {
    final kind = await _pickKind(medicalSlotKinds, 'md_slot_');
    if (kind == null || !mounted) return;
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: '${'md_slot_$kind'.tr} · ${_date(_day)}',
        fields: [
          DialogField('from', 'md_from'.tr, required: true, initial: '09:00'),
          DialogField('to', 'md_to'.tr, required: true, initial: '11:00'),
          DialogField('step', 'md_step'.tr,
              number: true, required: true, initial: '15'),
        ],
        okLabel: 'md_open_slots'.tr,
      ),
    );
    if (values == null || !mounted) return;
    await _run(
        openMedicalSlots(_day,
            kind: kind,
            from: values['from'] ?? '',
            to: values['to'] ?? '',
            step: values['step'] ?? ''),
        done: (r) => 'md_opened'.trParams({'count': '${r.count ?? 0}'}));
  }

  Future<void> _assign() async {
    final whom = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('md_assign'.tr),
        children: [
          for (final w in const ['person', 'department'])
            SimpleDialogOption(
              key: Key('md_assign_$w'),
              onPressed: () => Navigator.pop(context, w),
              child: Text('md_assign_$w'.tr),
            ),
        ],
      ),
    );
    if (whom == null || !mounted) return;
    AssignPerson? person;
    String? department;
    if (whom == 'person') {
      person = await showDialog<AssignPerson>(
          context: context,
          builder: (_) => PersonPickerDialog(
              title: 'md_assign_person'.tr, search: searchMedicalPeople));
      if (person == null || !mounted) return;
    } else {
      List<String> departments;
      try {
        departments = await fetchMedicalDepartments();
      } catch (_) {
        if (mounted) _show('it_err_failed'.tr);
        return;
      }
      if (!mounted) return;
      department = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text('md_assign_department'.tr),
          children: [
            for (final d in departments)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, d),
                child: Text(d),
              ),
          ],
        ),
      );
      if (department == null || !mounted) return;
    }
    final kind = await _pickKind(medicalExamKinds, 'md_exam_');
    if (kind == null || !mounted) return;
    final due = await showDatePicker(
      context: context,
      initialDate: _day.add(const Duration(days: 14)),
      firstDate: _day,
      lastDate: _day.add(const Duration(days: 365)),
    );
    if (due == null || !mounted) return;
    await _run(
        setMedicalExam(
            kind: kind,
            dueOn: due,
            employeeId: person?.id,
            department: department),
        done: (r) => 'md_assigned'.trParams({'count': '${r.count ?? 0}'}));
  }

  Future<void> _done(MedicalExam exam) async {
    final ok = await _confirm('md_done_confirm'.trParams({
      'name': exam.employee?.name ?? '',
      'kind': 'md_exam_${exam.kind}'.tr,
    }));
    if (!ok || !mounted) return;
    await _run(markMedicalExamDone(exam.id));
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
        title: BigText(content: 'md_title'.tr, color: Colors.white),
        actions: [
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
                  Tab(text: 'md_tab_mine'.tr),
                  Tab(text: 'md_tab_desk'.tr),
                ],
              ),
      ),
      body: body,
    );
    return desk == null
        ? scaffold
        : DefaultTabController(length: 2, child: scaffold);
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
        child: Text(text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Text(text, style: TextStyle(color: context.mutedColor)),
      );

  Widget _card({required Widget child, Key? key, Color? border}) => Container(
        key: key,
        margin:
            EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: context.cardSurface,
          borderRadius: BorderRadius.circular(10),
          boxShadow: context.cardShadow,
          border: border == null
              ? null
              : Border.all(color: border.withOpacity(0.6)),
        ),
        child: child,
      );

  Widget _exam(MedicalExam exam, {Widget? action}) {
    final color = context.readable(_stateColor(exam.state));
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    return _card(
      key: Key('md_exam_${exam.id}'),
      border: exam.state == 'ok' ? null : color,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    exam.employee == null
                        ? 'md_exam_${exam.kind}'.tr
                        : exam.employee!.name,
                    style: const TextStyle(fontSize: 15)),
                if (exam.employee != null)
                  Text(
                      [
                        'md_exam_${exam.kind}'.tr,
                        if (exam.employee!.department.isNotEmpty)
                          exam.employee!.department,
                      ].join(' · '),
                      style: muted),
                Text(
                    [
                      'md_due_on'.trParams({'date': _date(exam.dueOn)}),
                      if (exam.state != 'ok') 'md_state_${exam.state}'.tr,
                    ].join(' · '),
                    key: Key('md_due_${exam.id}'),
                    style: TextStyle(
                        fontSize: 12,
                        color: color,
                        fontWeight:
                            exam.state == 'ok' ? null : FontWeight.w600)),
                if (exam.lastDoneOn != null)
                  Text(
                      'md_last_done'.trParams({'date': _date(exam.lastDoneOn)}),
                      style: muted),
              ],
            ),
          ),
          if (action != null) action,
        ],
      ),
    );
  }

  Widget _mineView() {
    final mine = _mine;
    final byDay = <String, List<MedicalSlot>>{};
    for (final slot in mine.free) {
      byDay.putIfAbsent(_date(slot.startsAt), () => []).add(slot);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          _heading('md_exams'.tr),
          if (mine.exams.isEmpty) _hint('md_exams_empty'.tr),
          for (final exam in mine.exams) _exam(exam),
          if (mine.bookings.isNotEmpty) ...[
            _heading('md_bookings'.tr),
            for (final slot in mine.bookings)
              _card(
                key: Key('md_booking_${slot.id}'),
                border: context.accentColor,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                          '${_date(slot.startsAt)} ${_time(slot.startsAt)} · '
                          '${'md_slot_${slot.kind}'.tr}',
                          style: const TextStyle(fontSize: 15)),
                    ),
                    TextButton(
                      key: Key('md_cancel_${slot.id}'),
                      onPressed: _busy ? null : () => _cancel(slot),
                      child: Text('md_cancel'.tr),
                    ),
                  ],
                ),
              ),
          ],
          _heading('md_free'.tr),
          if (byDay.isEmpty) _hint('md_free_empty'.tr),
          for (final entry in byDay.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(entry.key,
                  style: TextStyle(color: context.mutedColor, fontSize: 13)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final slot in entry.value)
                    ActionChip(
                      key: Key('md_slot_${slot.id}'),
                      label: Text(
                          '${_time(slot.startsAt)} · ${'md_slot_${slot.kind}'.tr}'),
                      onPressed: _busy ? null : () => _book(slot),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _deskView(MedicalDesk desk) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  key: const Key('md_prev_day'),
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _busy ? null : () => _shiftDay(-1),
                ),
                Expanded(
                  child: Text('md_slots_day'.trParams({'date': _date(_day)}),
                      key: const Key('md_day'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  key: const Key('md_next_day'),
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _busy ? null : () => _shiftDay(1),
                ),
              ],
            ),
          ),
          if (desk.slots.isEmpty) _hint('md_slots_empty'.tr),
          for (final slot in desk.slots)
            _card(
              key: Key('md_desk_slot_${slot.id}'),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(_time(slot.startsAt),
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: Text(
                        '${'md_slot_${slot.kind}'.tr} · '
                        '${slot.employee?.name ?? 'md_free_slot'.tr}',
                        style: TextStyle(
                            color: slot.booked ? null : context.mutedColor)),
                  ),
                  IconButton(
                    key: Key('md_delete_${slot.id}'),
                    icon: const Icon(Icons.delete_outline),
                    onPressed:
                        _busy ? null : () => _run(deleteMedicalSlot(slot.id)),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const Key('md_open_slots'),
                  onPressed: _busy ? null : _openSlots,
                  icon: const Icon(Icons.more_time),
                  label: Text('md_open_slots'.tr),
                ),
                OutlinedButton.icon(
                  key: const Key('md_assign'),
                  onPressed: _busy ? null : _assign,
                  icon: const Icon(Icons.event_available_outlined),
                  label: Text('md_assign'.tr),
                ),
              ],
            ),
          ),
          _heading('md_due_list'.tr),
          if (desk.due.isEmpty) _hint('md_due_empty'.tr),
          for (final exam in desk.due)
            _exam(exam,
                action: TextButton(
                  key: Key('md_done_${exam.id}'),
                  onPressed: _busy ? null : () => _done(exam),
                  child: Text('md_done'.tr),
                )),
          if (desk.due.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: OutlinedButton.icon(
                key: const Key('md_remind'),
                onPressed: _busy
                    ? null
                    : () => _run(remindMedicalDue(),
                        done: (r) => 'md_reminded'
                            .trParams({'count': '${r.count ?? 0}'})),
                icon: const Icon(Icons.notifications_active_outlined),
                label: Text('md_remind'.tr),
              ),
            ),
        ],
      ),
    );
  }
}
