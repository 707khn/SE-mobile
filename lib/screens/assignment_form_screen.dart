import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';

/// Дать поручение одному или нескольким исполнителям.
class AssignmentFormScreen extends StatefulWidget {
  const AssignmentFormScreen({Key? key}) : super(key: key);

  @override
  State<AssignmentFormScreen> createState() => _AssignmentFormScreenState();
}

class _AssignmentFormScreenState extends State<AssignmentFormScreen> {
  final _title = TextEditingController();
  final _text = TextEditingController();
  final List<AssignPerson> _people = [];
  DateTime? _due;
  bool _important = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _text.dispose();
    super.dispose();
  }

  String _errorText(String? code) {
    for (final key in ['asg_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _due ?? today.add(const Duration(days: 3)),
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (picked != null && mounted) setState(() => _due = picked);
  }

  Future<void> _addPerson() async {
    final person = await showDialog<AssignPerson>(
        context: context, builder: (_) => const _AssigneePicker());
    if (person == null || !mounted) return;
    if (_people.any((p) => p.id == person.id)) return;
    setState(() => _people.add(person));
  }

  Future<void> _send() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'asg_err_title_required'.tr);
      return;
    }
    if (_due == null) {
      setState(() => _error = 'asg_err_bad_date'.tr);
      return;
    }
    if (_people.isEmpty) {
      setState(() => _error = 'asg_err_assignee_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await createAssignments(
      title: title,
      text: _text.text.trim(),
      dueDate: _due!,
      important: _important,
      assigneeIds: [for (final p in _people) p.id],
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(result.items);
      return;
    }
    setState(() {
      _sending = false;
      _error = _errorText(result.error);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'asg_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            key: const Key('asg_title'),
            controller: _title,
            maxLength: 300,
            decoration: InputDecoration(
              labelText: 'asg_title_field'.tr,
              hintText: 'asg_title_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('asg_text'),
            controller: _text,
            maxLength: 4000,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: 'asg_text_field'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('asg_due'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48)),
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event),
                  label: Text(_due == null
                      ? 'asg_due_field'.tr
                      : '${'asg_due_field'.tr}: ${DateFormat('dd.MM.yyyy').format(_due!)}'),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                key: const Key('asg_important'),
                avatar: const Icon(Icons.priority_high, size: 18),
                label: Text('asg_important'.tr),
                selected: _important,
                onSelected: (v) => setState(() => _important = v),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('asg_assignees'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('asg_assignees_hint'.tr,
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final p in _people)
                InputChip(
                  label: Text(p.name),
                  onDeleted: () => setState(() => _people.remove(p)),
                ),
              ActionChip(
                key: const Key('asg_add_assignee'),
                avatar: const Icon(Icons.person_add_alt, size: 18),
                label: Text('asg_add_assignee'.tr),
                onPressed: _addPerson,
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('asg_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('asg_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('asg_send'.tr),
            ),
          ),
        ],
      ),
    );
  }
}

/// Поиск исполнителя среди тех, кому можно поручать. Без запроса — первые
/// по алфавиту: у начальника отдела их немного, и искать не нужно.
class _AssigneePicker extends StatefulWidget {
  const _AssigneePicker();

  @override
  State<_AssigneePicker> createState() => _AssigneePickerState();
}

class _AssigneePickerState extends State<_AssigneePicker> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<AssignPerson> _found = const [];
  bool _searching = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(text));
  }

  Future<void> _search(String text) async {
    final seq = ++_seq;
    setState(() => _searching = true);
    List<AssignPerson> found;
    try {
      found = await searchAssignees(text.trim());
    } catch (_) {
      found = const [];
    }
    // Ответ на старый запрос пришёл позже нового — не показываем.
    if (!mounted || seq != _seq) return;
    setState(() {
      _found = found;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('asg_add_assignee'.tr),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              key: const Key('asg_search'),
              controller: _query,
              onChanged: _changed,
              decoration: InputDecoration(
                hintText: 'asg_search'.tr,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                child: ListView(
                  children: [
                    for (final p in _found)
                      ListTile(
                        key: Key('asg_found_${p.id}'),
                        dense: true,
                        title: Text(p.name),
                        subtitle: Text(
                            [p.jobTitle, p.department]
                                .where((s) => s.isNotEmpty)
                                .join(', '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(context, p),
                      ),
                  ],
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
