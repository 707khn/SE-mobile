import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/pre_trip_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'pre_trip_forms.dart';

Color preTripStatusColor(String status) => switch (status) {
      'admitted' => const Color(0xFF2E7D32),
      'not_admitted' => const Color(0xFFC62828),
      'med_ok' => const Color(0xFF1565C0),
      _ => const Color(0xFF757575),
    };

/// «Давление 125/80 · пульс 72 · 36,6 °C · алкоголь 0».
String preTripVitals(PreTripExam exam) {
  // 36.0 и 0.0 — как «36» и «0», 36.6 — как «36,6».
  String n(num? v) => v == null
      ? '—'
      : (v == v.roundToDouble() ? '${v.round()}' : '$v'.replaceAll('.', ','));
  return 'pt_vitals'.trParams({
    'sys': n(exam.systolic),
    'dia': n(exam.diastolic),
    'pulse': n(exam.pulse),
    'temp': n(exam.temperature),
    'alc': n(exam.alcohol),
  });
}

/// Водителю — свой допуск; медпункту, механику и руководству — журнал дня.
class PreTripScreen extends StatefulWidget {
  const PreTripScreen({Key? key}) : super(key: key);

  @override
  State<PreTripScreen> createState() => _PreTripScreenState();
}

class _PreTripScreenState extends State<PreTripScreen> {
  PreTripDay? _day;
  DateTime? _date;
  bool _loading = true;
  LoadProblem? _problem;

  bool get _isToday {
    final now = DateTime.now();
    final d = _date;
    return d == null ||
        (d.year == now.year && d.month == now.month && d.day == now.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final day = await fetchPreTripDay(day: _date);
      if (!mounted) return;
      setState(() {
        _day = day;
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

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? today,
      firstDate: today.subtract(const Duration(days: 366)),
      lastDate: today,
    );
    if (picked == null || !mounted) return;
    _date = picked;
    _load();
  }

  Future<void> _openForm(Widget form) async {
    final saved = await Get.to<bool>(() => form);
    if (!mounted) return;
    if (saved == true) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('pt_saved'.tr)));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    final journal = day?.rows != null;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'pt_title'.tr, color: Colors.white),
        actions: [
          if (journal)
            IconButton(
              key: const Key('pt_date'),
              icon: const Icon(Icons.calendar_month),
              tooltip: DateFormat('dd.MM.yyyy').format(day!.date),
              onPressed: _loading ? null : _pickDate,
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading && day == null
          ? const Center(child: CircularProgressIndicator())
          : day == null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    children: [
                      if (day.me != null) ..._mine(day.me!),
                      if (journal) ..._journal(day),
                    ],
                  ),
                ),
    );
  }

  List<Widget> _mine(PreTripMe me) {
    final color = context.readable(preTripStatusColor(me.status));
    return [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('pt_my_status'.tr,
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
            const SizedBox(height: 4),
            Text('pt_status_${me.status}'.tr,
                key: const Key('pt_my_status'),
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600, color: color)),
            if (me.exam != null) ...[
              const SizedBox(height: 6),
              Text(preTripVitals(me.exam!),
                  style: const TextStyle(fontSize: 13)),
              if (!me.exam!.admitted && me.exam!.reason.isNotEmpty)
                Text(me.exam!.reason, style: const TextStyle(fontSize: 13)),
            ],
            if (me.check != null) ...[
              const SizedBox(height: 4),
              Text(
                  '${'pt_vehicle'.trParams({'plate': me.check!.plate})} · '
                  '${me.check!.ok ? 'pt_vehicle_ok'.tr : me.check!.reason}',
                  style: const TextStyle(fontSize: 13)),
            ],
          ],
        ),
      ),
      const SizedBox(height: 20),
      Text('pt_history'.tr,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      if (me.history.isEmpty)
        Text('pt_no_history'.tr, style: TextStyle(color: context.mutedColor)),
      for (final e in me.history)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(e.admitted ? Icons.check_circle : Icons.block,
              color: context.readable(e.admitted
                  ? const Color(0xFF2E7D32)
                  : const Color(0xFFC62828))),
          title: Text(
              '${e.at == null ? '' : DateFormat('dd.MM HH:mm').format(e.at!)} · '
              '${'pt_kind_${e.kind}'.tr}'),
          subtitle: Text(preTripVitals(e)),
        ),
      const SizedBox(height: 16),
    ];
  }

  List<Widget> _journal(PreTripDay day) {
    final rows = day.rows!;
    final c = day.counts;
    return [
      Text(
          _isToday
              ? '${'pt_today'.tr}, ${DateFormat('dd.MM.yyyy').format(day.date)}'
              : DateFormat('dd.MM.yyyy').format(day.date),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Text(
          'pt_counts'.trParams({
            'admitted': '${c['admitted'] ?? 0}',
            'not': '${c['not_admitted'] ?? 0}',
            'pending': '${(c['pending'] ?? 0) + (c['med_ok'] ?? 0)}',
          }),
          key: const Key('pt_counts'),
          style: TextStyle(fontSize: 12, color: context.mutedColor)),
      const SizedBox(height: 8),
      if (rows.isEmpty)
        Text('pt_no_drivers'.tr, style: TextStyle(color: context.mutedColor)),
      for (final row in rows) _row(day, row),
    ];
  }

  Widget _row(PreTripDay day, PreTripRow row) {
    final color = context.readable(preTripStatusColor(row.status));
    final details = <String>[
      if (row.exam != null && row.exam!.hasVitals) preTripVitals(row.exam!),
      if (row.exam != null &&
          !row.exam!.admitted &&
          row.exam!.reason.isNotEmpty)
        row.exam!.reason,
      if (row.check != null)
        '${'pt_vehicle'.trParams({'plate': row.check!.plate})}'
            '${row.check!.ok ? '' : ' — ${row.check!.reason}'}',
    ];
    final warn = row.exam?.warnings.isNotEmpty ?? false;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.driver.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('pt_short_${row.status}'.tr,
                    key: Key('pt_status_${row.driver.id}'),
                    style: TextStyle(
                        fontSize: 12,
                        color: color,
                        fontWeight: FontWeight.w600)),
                for (final d in details)
                  Text(d,
                      style: TextStyle(
                          fontSize: 12,
                          color: warn ? null : context.mutedColor)),
              ],
            ),
          ),
          if (_isToday && day.medic)
            TextButton(
              key: Key('pt_exam_${row.driver.id}'),
              onPressed: () => _openForm(
                  PreTripExamScreen(driver: row.driver, limits: day.limits)),
              child: Text('pt_exam'.tr),
            ),
          if (_isToday && day.mechanic)
            TextButton(
              key: Key('pt_check_${row.driver.id}'),
              onPressed: () => _openForm(VehicleCheckScreen(
                  driver: row.driver, lastPlate: row.check?.plate ?? '')),
              child: Text('pt_check'.tr),
            ),
        ],
      ),
    );
  }
}
