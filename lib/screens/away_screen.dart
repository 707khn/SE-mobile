import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/away_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../utils/search_fold.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';

/// «Меня нет на месте»: отпуск, больничный, командировка — до какого числа
/// и кто замещает. Видно всем в справочнике под именем человека.
class AwayScreen extends StatefulWidget {
  const AwayScreen({Key? key, this.names = const [], this.today})
      : super(key: key);

  /// ФИО из справочника — подсказки для поля «Кто замещает».
  final List<String> names;

  /// Подменяется в проверках.
  final DateTime? today;

  @override
  State<AwayScreen> createState() => _AwayScreenState();
}

class _AwayScreenState extends State<AwayScreen> {
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  AwayNote? _current;
  int _maxDays = 120;

  String _reason = 'vacation';
  DateTimeRange? _range;
  final _deputy = TextEditingController();
  final _note = TextEditingController();
  String? _error;

  DateTime get _today {
    final now = widget.today ?? DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _deputy.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final state = await fetchAway();
      if (!mounted) return;
      setState(() {
        _current = state.note;
        _maxDays = state.maxDays;
        _fill(state.note);
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

  void _fill(AwayNote? note) {
    if (note == null) return;
    _reason = note.reason;
    _range = DateTimeRange(start: note.start, end: note.end);
    _deputy.text = note.deputy;
    _note.text = note.note;
  }

  Future<void> _pickDates() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: _today,
      lastDate: _today.add(const Duration(days: 60 + 120)),
      initialDateRange: _range,
      helpText: 'away_dates'.tr,
    );
    if (picked != null) setState(() => _range = picked);
  }

  String _errorText(String? code) {
    final key = 'away_err_$code';
    return code != null && key.tr != key ? key.tr : 'it_err_failed'.tr;
  }

  Future<void> _save() async {
    final range = _range;
    if (range == null) {
      setState(() => _error = 'away_err_bad_dates'.tr);
      return;
    }
    if (range.duration.inDays + 1 > _maxDays) {
      setState(() => _error = 'away_err_too_long'.tr);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await saveAway(
      reason: _reason,
      start: range.start,
      end: range.end,
      deputy: _deputy.text.trim(),
      note: _note.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        _current = result.note;
      } else {
        _error = _errorText(result.error);
      }
    });
    if (result.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('away_saved'.tr)));
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    final result = await clearAway();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) {
        _current = null;
        _range = null;
        _deputy.clear();
        _note.clear();
      } else {
        _error = _errorText(result.error);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'away_title'.tr, color: Colors.white),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : _form(),
    );
  }

  Widget _form() {
    final format = DateFormat('dd.MM.yyyy');
    final range = _range;
    final current = _current;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text('away_intro'.tr,
            style: TextStyle(fontSize: 13, color: context.mutedColor)),
        if (current != null) ...[
          const SizedBox(height: 12),
          Container(
            key: const Key('away_current'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.accentColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              awayLine(current),
              style: TextStyle(color: context.accentColor),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final reason in awayReasons)
              ChoiceChip(
                label: Text('away_reason_$reason'.tr),
                selected: _reason == reason,
                onSelected: (_) => setState(() => _reason = reason),
              ),
          ],
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          key: const Key('away_dates'),
          onPressed: _busy ? null : _pickDates,
          icon: const Icon(Icons.date_range),
          label: Text(range == null
              ? 'away_dates'.tr
              : '${format.format(range.start)} — ${format.format(range.end)}'),
        ),
        const SizedBox(height: 16),
        Autocomplete<String>(
          optionsBuilder: (value) {
            final query = value.text.trim();
            if (query.length < 2) return const Iterable<String>.empty();
            return widget.names
                .where((n) => matchesQuery(n, query))
                .take(8);
          },
          onSelected: (name) => _deputy.text = name,
          fieldViewBuilder: (context, controller, focus, onSubmit) {
            if (controller.text.isEmpty && _deputy.text.isNotEmpty) {
              controller.text = _deputy.text;
            }
            return TextField(
              key: const Key('away_deputy'),
              controller: controller,
              focusNode: focus,
              onChanged: (value) => _deputy.text = value,
              decoration: InputDecoration(
                labelText: 'away_deputy'.tr,
                hintText: 'away_deputy_hint'.tr,
                border: const OutlineInputBorder(),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('away_note'),
          controller: _note,
          maxLength: 200,
          decoration: InputDecoration(
            labelText: 'away_note'.tr,
            hintText: 'away_note_hint'.tr,
            border: const OutlineInputBorder(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!,
              key: const Key('away_error'),
              style: TextStyle(color: Colors.red.shade700)),
        ],
        const SizedBox(height: 16),
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            key: const Key('away_save'),
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.check),
            label: Text('away_save'.tr),
          ),
        ),
        if (current != null) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            key: const Key('away_clear'),
            onPressed: _busy ? null : _clear,
            icon: const Icon(Icons.event_available),
            label: Text('away_clear'.tr),
          ),
        ],
      ],
    );
  }
}

/// «В отпуске до 04.11, замещает Иванов И. И.» — одна строка для экрана
/// отметки и для справочника.
String awayLine(AwayNote note) {
  final until = DateFormat('dd.MM').format(note.end);
  final head = 'away_line_${note.reason}'.trParams({'date': until});
  if (note.deputy.isEmpty) return head;
  return '$head · ${'away_deputy_short'.trParams({'name': note.deputy})}';
}
