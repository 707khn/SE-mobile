import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/crash_request.dart';
import '../utils/app_theme.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/load_error_view.dart';

/// «Ошибки приложения»: что падает у людей, на какой сборке и у скольких.
///
/// Раньше ошибку было видно, только если человек сам открыл «О программе» и
/// переслал журнал. Теперь телефоны присылают её сами, а здесь она собрана:
/// одна и та же ошибка у двадцати человек — одна строка с числом двадцать.
class CrashesScreen extends StatefulWidget {
  const CrashesScreen({Key? key}) : super(key: key);

  @override
  State<CrashesScreen> createState() => _CrashesScreenState();
}

class _CrashesScreenState extends State<CrashesScreen> {
  CrashesReport? _report;
  bool _loading = true;
  LoadProblem? _problem;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final report = await fetchCrashes();
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
        _problem = problemOfAny(e);
      });
    }
  }

  Future<void> _forget(CrashGroup group) async {
    final ok = await forgetCrash(group.fingerprint);
    if (!mounted) return;
    Get.snackbar(ok ? 'crashes_fixed_done'.tr : 'load_error'.tr, '',
        snackPosition: SnackPosition.BOTTOM,
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 2));
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: Text('crashes_title'.tr),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error || _report == null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.all(Dimensions.width20),
                    children: _body(_report!),
                  ),
                ),
    );
  }

  List<Widget> _body(CrashesReport r) {
    final gap = SizedBox(height: Dimensions.height30 / 1.5);
    return [
      if (r.spikePeople != null) ...[_spike(r), gap],
      _section('crashes_errors'.tr),
      if (r.groups.isEmpty)
        _line('crashes_none'.tr, '', muted: true)
      else
        ...r.groups.map(_group),
      gap,
      _section('crashes_versions'.tr),
      ...r.versions.map((v) => _line(
          v.version.isEmpty ? 'crashes_unknown_version'.tr : v.version,
          'crashes_version_line'
              .trParams({'users': '${v.users}', 'people': '${v.people}'}),
          warn: v.people > 0)),
      gap,
      _section('crashes_days'.tr),
      ...r.days.where((d) => d.day != null).map((d) => _line(
          DateFormat('dd.MM').format(d.day!),
          d.count == 0
              ? '0'
              : 'crashes_group_meta'
                  .trParams({'count': '${d.count}', 'people': '${d.people}'}),
          warn: d.count > 0)),
      SizedBox(height: Dimensions.height30 / 2),
      Text('crashes_why'.tr,
          style: TextStyle(fontSize: 12, color: context.mutedColor, height: 1.4)),
    ];
  }

  Widget _spike(CrashesReport r) {
    final color = Colors.orange.shade800;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'crashes_spike'.trParams({
                'people': '${r.spikePeople}',
                'usual': (r.spikeUsual ?? 0).toStringAsFixed(0),
              }),
              style: TextStyle(
                  fontSize: 14.5,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _group(CrashGroup g) {
    final last = g.lastAt == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(g.lastAt!.toLocal());
    final meta = [
      'crashes_group_meta'
          .trParams({'count': '${g.count}', 'people': '${g.people}'}),
      if (g.versions.isNotEmpty) g.versions.join(', '),
      if (last.isNotEmpty) last,
    ].join(' · ');
    final details = [
      if (g.where.isNotEmpty) g.where,
      if (g.platforms.isNotEmpty) g.platforms.join(', '),
      if (g.names.isNotEmpty) g.names.join(', '),
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text(g.error,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13.5, color: context.inkColor)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(meta,
              style: TextStyle(fontSize: 11.5, color: context.mutedColor)),
        ),
        children: [
          for (final d in details)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(d,
                  style: TextStyle(fontSize: 12, color: context.mutedColor)),
            ),
          if (g.stack.isNotEmpty)
            SelectableText(g.stack,
                style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: context.inkColor)),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                      text: [g.error, g.where, g.stack, meta]
                          .where((s) => s.isNotEmpty)
                          .join('\n')));
                  Get.snackbar('about_copied'.tr, '',
                      snackPosition: SnackPosition.BOTTOM,
                      margin: const EdgeInsets.all(12),
                      duration: const Duration(seconds: 2));
                },
                child: Text('crashes_copy'.tr),
              ),
              TextButton(
                onPressed: () => _forget(g),
                child: Text('crashes_fixed'.tr),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      );

  Widget _line(String label, String value,
      {bool muted = false, bool warn = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 13.5,
                    color: muted ? context.mutedColor : context.inkColor)),
          ),
          const SizedBox(width: 10),
          Text(value,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: warn ? Colors.orange.shade800 : AppColors.mainColor)),
        ],
      ),
    );
  }
}
