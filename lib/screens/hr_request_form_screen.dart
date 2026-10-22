import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/hr_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../widgets/custom_text.dart';

/// Новая заявка в отдел кадров. Возвращает созданную заявку через Get.back.
class HrRequestFormScreen extends StatefulWidget {
  const HrRequestFormScreen({Key? key, this.kind = 'employment'})
      : super(key: key);

  final String kind;

  @override
  State<HrRequestFormScreen> createState() => _HrRequestFormScreenState();
}

/// Виды отпуска, которые подают заявлением. Названия — как в 1С и на
/// экране «Отпуска», чтобы кадрам не переводить.
const hrLeaveTypes = [
  'Ежегодный трудовой отпуск',
  'Экологический отпуск',
  'Отпуск без сохранения заработной платы',
];

class _HrRequestFormScreenState extends State<HrRequestFormScreen> {
  late String _kind = widget.kind;
  final _details = TextEditingController();
  int _copies = 1;
  String _leaveType = hrLeaveTypes.first;
  DateTimeRange? _range;
  bool _sending = false;

  @override
  void dispose() {
    _details.dispose();
    super.dispose();
  }

  bool get _ready => _kind != 'vacation' || _range != null;

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      initialDateRange: _range,
    );
    if (picked != null) setState(() => _range = picked);
  }

  Future<void> _send() async {
    if (!_ready || _sending) return;
    setState(() => _sending = true);
    final vacation = _kind == 'vacation';
    final result = await createHrRequest(
      kind: _kind,
      details: _details.text.trim(),
      copies: vacation ? 1 : _copies,
      leaveType: vacation ? _leaveType : null,
      startDate: vacation ? _range!.start : null,
      endDate: vacation ? _range!.end : null,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (result.ok) {
      Get.back(result: result.item);
      return;
    }
    // Набранное остаётся на экране: не ушло — отправят ещё раз.
    final message = switch (result.error) {
      'too_many_open' => 'hr_too_many'.tr,
      'bad_period' => 'hr_bad_period'.tr,
      _ => 'hr_save_failed'.tr,
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final vacation = _kind == 'vacation';
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'hr_new'.tr, color: Colors.white),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(Dimensions.width20),
          children: [
            Text('hr_what'.tr,
                style: TextStyle(fontSize: 13, color: context.mutedColor)),
            const SizedBox(height: 8),
            RadioGroup<String>(
              groupValue: _kind,
              onChanged: (v) => setState(() => _kind = v ?? _kind),
              child: Column(
                children: [
                  for (final kind in const ['employment', 'income', 'vacation'])
                    RadioListTile<String>(
                      value: kind,
                      contentPadding: EdgeInsets.zero,
                      title: Text(hrKindKey(kind).tr),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (vacation) ...[
              DropdownButtonFormField<String>(
                initialValue: _leaveType,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'hr_leave_type'.tr,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final t in hrLeaveTypes)
                    DropdownMenuItem(value: t, child: Text(t)),
                ],
                onChanged: (v) => setState(() => _leaveType = v ?? _leaveType),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickRange,
                icon: const Icon(Icons.date_range),
                label: Text(_range == null
                    ? 'hr_pick_dates'.tr
                    : '${DateFormat('dd.MM.yyyy').format(_range!.start)} — '
                        '${DateFormat('dd.MM.yyyy').format(_range!.end)} '
                        '(${_range!.end.difference(_range!.start).inDays + 1} ${'days_short'.tr})'),
              ),
              const SizedBox(height: 12),
            ] else ...[
              Row(
                children: [
                  Expanded(child: Text('hr_copies'.tr)),
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed:
                        _copies > 1 ? () => setState(() => _copies--) : null,
                  ),
                  Text('$_copies', style: const TextStyle(fontSize: 16)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed:
                        _copies < 5 ? () => setState(() => _copies++) : null,
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _details,
              maxLines: 3,
              maxLength: 1000,
              decoration: InputDecoration(
                labelText: vacation ? 'hr_comment'.tr : 'hr_purpose'.tr,
                hintText: switch (_kind) {
                  'income' => 'hr_purpose_income_hint'.tr,
                  'vacation' => null,
                  _ => 'hr_purpose_hint'.tr,
                },
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _ready && !_sending ? _send : null,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('hr_send'.tr),
            ),
          ],
        ),
      ),
    );
  }
}
