import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart' show AssignPerson;
import '../requests/work_permit_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';
import '../widgets/person_picker_dialog.dart';

/// Выписать наряд: вид и место работ, время, люди и меры безопасности.
class WorkPermitFormScreen extends StatefulWidget {
  const WorkPermitFormScreen({Key? key, this.measures = const {}, this.now})
      : super(key: key);

  /// Меры по виду работ, что предлагает сервер.
  final Map<String, List<String>> measures;

  /// Для проверок: от какого «сейчас» считать время по умолчанию.
  final DateTime? now;

  @override
  State<WorkPermitFormScreen> createState() => _WorkPermitFormScreenState();
}

class _WorkPermitFormScreenState extends State<WorkPermitFormScreen> {
  final _place = TextEditingController();
  final _work = TextEditingController();
  final _members = TextEditingController();
  final _extra = TextEditingController();
  String _kind = 'fire';
  late DateTime _starts;
  late DateTime _ends;
  AssignPerson? _performer;
  AssignPerson? _responsible;
  AssignPerson? _admitter;
  List<String> _measures = const [];
  final List<String> _custom = [];
  final Set<String> _unchecked = {};
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final now = widget.now ?? DateTime.now();
    // Ближайший целый час — так наряды и пишут.
    _starts = DateTime(now.year, now.month, now.day, now.hour + 1);
    _ends = _starts.add(const Duration(hours: 8));
    _measures = [...widget.measures[_kind] ?? const <String>[]];
  }

  @override
  void dispose() {
    for (final c in [_place, _work, _members, _extra]) {
      c.dispose();
    }
    super.dispose();
  }

  void _setKind(String kind) {
    setState(() {
      _kind = kind;
      _measures = [...widget.measures[kind] ?? const <String>[]];
      _unchecked.clear();
    });
  }

  void _addMeasure() {
    final text = _extra.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _custom.add(text);
      _extra.clear();
    });
  }

  Future<void> _pickTime(bool start) async {
    final current = start ? _starts : _ends;
    final day = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(current.year - 1),
      lastDate: DateTime(current.year + 1),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null || !mounted) return;
    final picked =
        DateTime(day.year, day.month, day.day, time.hour, time.minute);
    setState(() {
      if (start) {
        final span = _ends.difference(_starts);
        _starts = picked;
        _ends = picked.add(span);
      } else {
        _ends = picked;
      }
    });
  }

  Future<void> _pickPerson(String role) async {
    final person = await showDialog<AssignPerson>(
        context: context,
        builder: (_) => PersonPickerDialog(
            title: 'wp_$role'.tr, search: searchPermitPeople));
    if (person == null || !mounted) return;
    setState(() {
      switch (role) {
        case 'performer':
          _performer = person;
        case 'responsible':
          _responsible = person;
        default:
          _admitter = person;
      }
    });
  }

  String _errorText(String? code) {
    for (final key in ['wp_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _send() async {
    final place = _place.text.trim();
    final work = _work.text.trim();
    final measures = [..._measures, ..._custom]
        .where((m) => !_unchecked.contains(m))
        .toList();
    final problem = place.isEmpty
        ? 'place_required'
        : work.isEmpty
            ? 'work_required'
            : _performer == null
                ? 'performer_required'
                : !_ends.isAfter(_starts)
                    ? 'bad_time'
                    : measures.isEmpty && _kind != 'other'
                        ? 'measures_required'
                        : null;
    if (problem != null) {
      setState(() => _error = _errorText(problem));
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await issueWorkPermit(
      kind: _kind,
      place: place,
      work: work,
      startsAt: _starts,
      endsAt: _ends,
      performerId: _performer!.id,
      responsibleId: _responsible?.id ?? '',
      admitterId: _admitter?.id ?? '',
      members: _members.text
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      measures: measures,
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(result.item);
      return;
    }
    setState(() {
      _sending = false;
      _error = _errorText(result.error);
    });
  }

  Widget _person(String role, AssignPerson? person, String empty) {
    return ListTile(
      key: Key('wp_pick_$role'),
      contentPadding: EdgeInsets.zero,
      title: Text('wp_$role'.tr,
          style: TextStyle(fontSize: 12, color: context.mutedColor)),
      subtitle:
          Text(person?.name ?? empty, style: const TextStyle(fontSize: 15)),
      trailing: person != null && role != 'performer'
          ? IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                if (role == 'responsible') {
                  _responsible = null;
                } else {
                  _admitter = null;
                }
              }),
            )
          : const Icon(Icons.chevron_right),
      onTap: () => _pickPerson(role),
    );
  }

  Widget _measure(String text) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(text),
      value: !_unchecked.contains(text),
      onChanged: (on) => setState(() {
        if (on == true) {
          _unchecked.remove(text);
        } else {
          _unchecked.add(text);
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final format = DateFormat('dd.MM.yyyy HH:mm');
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'wp_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text('wp_kind'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final kind in workPermitKinds)
                ChoiceChip(
                  key: Key('wp_kind_$kind'),
                  label: Text('wp_kind_$kind'.tr),
                  selected: _kind == kind,
                  onSelected: (_) => _setKind(kind),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('wp_place'),
            controller: _place,
            maxLength: 200,
            decoration: InputDecoration(
              labelText: 'wp_place'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('wp_work'),
            controller: _work,
            maxLength: 2000,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: 'wp_work'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: ListTile(
                  key: const Key('wp_starts'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('wp_starts'.tr,
                      style:
                          TextStyle(fontSize: 12, color: context.mutedColor)),
                  subtitle: Text(format.format(_starts)),
                  onTap: () => _pickTime(true),
                ),
              ),
              Expanded(
                child: ListTile(
                  key: const Key('wp_ends'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('wp_ends'.tr,
                      style:
                          TextStyle(fontSize: 12, color: context.mutedColor)),
                  subtitle: Text(format.format(_ends)),
                  onTap: () => _pickTime(false),
                ),
              ),
            ],
          ),
          _person('performer', _performer, 'wp_choose'.tr),
          _person('responsible', _responsible, 'wp_responsible_me'.tr),
          _person('admitter', _admitter, 'wp_admitter_none'.tr),
          const SizedBox(height: 8),
          TextField(
            key: const Key('wp_members'),
            controller: _members,
            minLines: 2,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: 'wp_members'.tr,
              hintText: 'wp_members_hint'.tr,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text('wp_measures'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          for (final m in [..._measures, ..._custom]) _measure(m),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('wp_measure_text'),
                  controller: _extra,
                  maxLength: 200,
                  onSubmitted: (_) => _addMeasure(),
                  decoration: InputDecoration(
                    hintText: 'wp_measure_hint'.tr,
                    counterText: '',
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                key: const Key('wp_measure_add'),
                tooltip: 'wp_measure_add'.tr,
                icon: const Icon(Icons.add),
                onPressed: _addMeasure,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('wp_paper_note'.tr,
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('wp_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('wp_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('wp_send'.tr),
            ),
          ),
        ],
      ),
    );
  }
}
