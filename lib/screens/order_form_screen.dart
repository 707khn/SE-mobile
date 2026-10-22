import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/order_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';

/// Разослать приказ на ознакомление: всему предприятию или отделам.
class OrderFormScreen extends StatefulWidget {
  const OrderFormScreen({Key? key}) : super(key: key);

  @override
  State<OrderFormScreen> createState() => _OrderFormScreenState();
}

class _OrderFormScreenState extends State<OrderFormScreen> {
  final _number = TextEditingController();
  final _title = TextEditingController();
  final _text = TextEditingController();
  final _link = TextEditingController();
  String _kind = 'order';
  DateTime? _docDate = DateTime.now();
  DateTime? _dueDate;
  Set<String> _departments = {};
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _number.dispose();
    _title.dispose();
    _text.dispose();
    _link.dispose();
    super.dispose();
  }

  String _errorText(String? code) {
    for (final key in ['ord_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<DateTime?> _pick(DateTime? initial, {bool future = false}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return showDatePicker(
      context: context,
      initialDate:
          initial ?? (future ? today.add(const Duration(days: 7)) : today),
      firstDate: future ? today : today.subtract(const Duration(days: 365)),
      lastDate: today.add(const Duration(days: 365)),
    );
  }

  Future<void> _pickDepartments() async {
    List<OrderDepartment> all;
    try {
      all = await fetchOrderDepartments();
    } catch (_) {
      if (mounted) setState(() => _error = 'it_err_failed'.tr);
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _DepartmentsDialog(all: all, selected: _departments),
    );
    if (picked != null && mounted) setState(() => _departments = picked);
  }

  Future<void> _send() async {
    final title = _title.text.trim();
    final text = _text.text.trim();
    final link = _link.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'ord_err_title_required'.tr);
      return;
    }
    if (text.isEmpty) {
      setState(() => _error = 'ord_err_text_required'.tr);
      return;
    }
    if (link.isNotEmpty &&
        !link.startsWith('https://') &&
        !link.startsWith('http://')) {
      setState(() => _error = 'ord_err_bad_link'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await publishOrder(
      kind: _kind,
      title: title,
      text: text,
      number: _number.text.trim(),
      docDate: _docDate,
      link: link,
      departments: _departments.toList()..sort(),
      dueDate: _dueDate,
    );
    if (!mounted) return;
    if (result.item != null) {
      Navigator.of(context).pop(result.item);
      return;
    }
    setState(() {
      _sending = false;
      _error = _errorText(result.error);
    });
  }

  @override
  Widget build(BuildContext context) {
    final day = DateFormat('dd.MM.yyyy');
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'ord_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text('ord_kind'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final kind in orderKinds)
                ChoiceChip(
                  key: Key('ord_kind_$kind'),
                  label: Text('ord_kind_$kind'.tr),
                  selected: _kind == kind,
                  onSelected: (_) => setState(() => _kind = kind),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('ord_number'),
                  controller: _number,
                  maxLength: 50,
                  decoration: InputDecoration(
                    labelText: 'ord_number_field'.tr,
                    border: const OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('ord_doc_date'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(56)),
                  onPressed: () async {
                    final picked = await _pick(_docDate);
                    if (picked != null && mounted) {
                      setState(() => _docDate = picked);
                    }
                  },
                  icon: const Icon(Icons.event),
                  label: Text(_docDate == null
                      ? 'ord_doc_date'.tr
                      : day.format(_docDate!)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('ord_title'),
            controller: _title,
            maxLength: 300,
            decoration: InputDecoration(
              labelText: 'ord_title_field'.tr,
              hintText: 'ord_title_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('ord_text'),
            controller: _text,
            maxLength: 20000,
            minLines: 6,
            maxLines: 16,
            decoration: InputDecoration(
              labelText: 'ord_text_field'.tr,
              hintText: 'ord_text_hint'.tr,
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('ord_link'),
            controller: _link,
            maxLength: 500,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'ord_link_field'.tr,
              hintText: 'https://',
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          Text('ord_audience'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                key: const Key('ord_audience_all'),
                label: Text('ord_audience_all'.tr),
                selected: _departments.isEmpty,
                onSelected: (_) => setState(() => _departments = {}),
              ),
              ActionChip(
                key: const Key('ord_pick_departments'),
                avatar: const Icon(Icons.apartment, size: 18),
                label: Text(_departments.isEmpty
                    ? 'ord_pick_departments'.tr
                    : 'ord_audience_some'
                        .trParams({'count': '${_departments.length}'})),
                onPressed: _pickDepartments,
              ),
            ],
          ),
          if (_departments.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text((_departments.toList()..sort()).join(', '),
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
          ],
          const SizedBox(height: 16),
          Text('ord_due_field'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text('ord_due_none'.tr),
                selected: _dueDate == null,
                onSelected: (_) => setState(() => _dueDate = null),
              ),
              ChoiceChip(
                key: const Key('ord_due'),
                label: Text(_dueDate == null
                    ? 'ord_pick_date'.tr
                    : day.format(_dueDate!)),
                selected: _dueDate != null,
                onSelected: (_) async {
                  final picked = await _pick(_dueDate, future: true);
                  if (picked != null && mounted) {
                    setState(() => _dueDate = picked);
                  }
                },
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('ord_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('ord_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('ord_send'.tr),
            ),
          ),
        ],
      ),
    );
  }
}

class _DepartmentsDialog extends StatefulWidget {
  const _DepartmentsDialog({required this.all, required this.selected});

  final List<OrderDepartment> all;
  final Set<String> selected;

  @override
  State<_DepartmentsDialog> createState() => _DepartmentsDialogState();
}

class _DepartmentsDialogState extends State<_DepartmentsDialog> {
  late final Set<String> _picked = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('ord_pick_departments'.tr),
      contentPadding: const EdgeInsets.only(top: 12),
      content: SizedBox(
        width: 480,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final d in widget.all)
              CheckboxListTile(
                dense: true,
                value: _picked.contains(d.name),
                title: Text(d.name),
                subtitle:
                    Text('ord_people_count'.trParams({'count': '${d.count}'})),
                onChanged: (v) => setState(() =>
                    v == true ? _picked.add(d.name) : _picked.remove(d.name)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('cancel'.tr)),
        TextButton(
            key: const Key('ord_departments_ok'),
            onPressed: () => Navigator.of(context).pop(_picked),
            child: const Text('OK')),
      ],
    );
  }
}
