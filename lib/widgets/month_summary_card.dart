import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/month_summary_request.dart';
import '../utils/app_theme.dart';
import '../utils/lang.dart';
import '../utils/load_problem.dart';
import '../utils/month_summary.dart';
import 'load_error_view.dart';

/// Итоги месяца над списком проходов: дни на работе, средний приход,
/// опоздания. Месяц листается стрелками.
///
/// Раньше был только список, и сколько дней человек был на работе и
/// опаздывал ли, он считал по нему сам.
class MonthSummaryCard extends StatefulWidget {
  const MonthSummaryCard({Key? key, this.employeeId, this.load})
      : super(key: key);

  /// Чужие итоги — для администратора; null — свои.
  final String? employeeId;

  /// Подмена запроса для проверок.
  final Future<MonthSummary?> Function(DateTime month)? load;

  @override
  State<MonthSummaryCard> createState() => _MonthSummaryCardState();
}

class _MonthSummaryCardState extends State<MonthSummaryCard> {
  late DateTime _month;
  MonthSummary? _summary;
  LoadProblem? _problem;
  bool _failed = false;
  bool _loading = true;

  /// Сервер итогов не знает — карточку не показываем вовсе.
  bool _unsupported = false;
  bool _showLate = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _failed = false;
      _showLate = false;
    });
    try {
      final load = widget.load ??
          (DateTime m) => getMonthSummary(m, employeeId: widget.employeeId);
      final summary = await load(_month);
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _summary = summary;
        _unsupported = summary == null;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _failed = true;
        _problem = problemOfAny(e);
      });
    }
  }

  DateTime get _thisMonth {
    final now = DateTime.now();
    return DateTime(now.year, now.month);
  }

  bool get _canGoBack {
    final first = _summary?.firstMonth;
    // Пока не знаем, с какого месяца проходы, — листать даём.
    return first == null || _month.isAfter(first);
  }

  bool get _canGoForward => _month.isBefore(_thisMonth);

  void _shift(int by) {
    setState(() => _month = DateTime(_month.year, _month.month + by));
    _load();
  }

  static String _title(DateTime month) {
    final text = DateFormat('LLLL yyyy', Lang.dates).format(month);
    return text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
  }

  @override
  Widget build(BuildContext context) {
    if (_unsupported) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'month_previous'.tr,
                  onPressed: _canGoBack ? () => _shift(-1) : null,
                ),
                Expanded(
                  child: Column(
                    children: [
                      Text('month_summary'.tr,
                          style: TextStyle(
                              fontSize: 12, color: context.mutedColor)),
                      Text(_title(_month),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'month_next'.tr,
                  onPressed: _canGoForward ? () => _shift(1) : null,
                ),
              ],
            ),
            const SizedBox(height: 4),
            _body(context),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (_failed) {
      return LoadErrorView(problem: _problem, onRetry: _load);
    }
    final s = _summary!;
    if (s.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        child: Text(
          s.notLoadedYet ? 'month_not_loaded'.tr : 'month_no_passes'.tr,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.mutedColor, fontSize: 13),
        ),
      );
    }
    final lateColor = context.readable(Colors.red.shade700);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _stat(context, '${s.daysPresent}', 'month_days_present'.tr),
              _stat(context, s.avgArrival ?? '—', 'month_avg_arrival'.tr),
              _stat(
                context,
                '${s.lateCount}',
                'month_late'.tr,
                color: s.lateCount > 0 ? lateColor : null,
                onTap: s.lateCount > 0
                    ? () => setState(() => _showLate = !_showLate)
                    : null,
              ),
            ],
          ),
          if (_showLate) ...[
            const SizedBox(height: 8),
            for (final d in s.lateDays)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(Icons.schedule, size: 15, color: lateColor),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(DateFormat('dd.MM, EEEE', Lang.dates)
                            .format(d.date))),
                    Text(d.firstIn ?? '',
                        style: TextStyle(
                            color: lateColor, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 8),
          Text(
            [
              if (s.avgDeparture != null)
                'month_avg_departure'.trParams({'time': s.avgDeparture!}),
              if (s.weekendDays > 0)
                'month_weekend_days'.trParams({'days': '${s.weekendDays}'}),
              'month_late_rule'.trParams({'time': s.workStart}),
            ].join(' · '),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.mutedColor),
          ),
          if (s.partial && s.coverage?.loadedUntil != null) ...[
            const SizedBox(height: 4),
            Text(
              'month_partial'.trParams({
                'date': DateFormat('dd.MM.yyyy').format(s.coverage!.loadedUntil!)
              }),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: context.mutedColor),
            ),
          ],
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String value, String label,
      {Color? color, VoidCallback? onTap}) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(label,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          if (onTap != null)
            Icon(_showLate ? Icons.expand_less : Icons.expand_more,
                size: 16, color: context.mutedColor),
        ],
      ),
    );
    return Expanded(
      child: onTap == null
          ? content
          : InkWell(
              borderRadius: BorderRadius.circular(8), onTap: onTap, child: content),
    );
  }
}
