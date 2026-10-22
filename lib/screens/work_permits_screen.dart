import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/work_permit_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'work_permit_detail_screen.dart';
import 'work_permit_form_screen.dart';

Color workPermitColor(String status) => switch (status) {
      'pending' => const Color(0xFF1565C0),
      'approved' => const Color(0xFF6A1B9A),
      'open' => const Color(0xFFE65100),
      'closed' => const Color(0xFF2E7D32),
      'rejected' || 'stopped' => const Color(0xFFC62828),
      _ => const Color(0xFF757575),
    };

class WorkPermitChip extends StatelessWidget {
  const WorkPermitChip({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(workPermitColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('wp_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// «15.01 09:00 – 17:00» или «15.01 09:00 – 16.01 17:00».
String workPermitSpan(WorkPermit item) {
  final start = item.startsAt, end = item.endsAt;
  if (start == null || end == null) return '';
  final sameDay = start.year == end.year &&
      start.month == end.month &&
      start.day == end.day;
  return '${DateFormat('dd.MM HH:mm').format(start)} – '
      '${DateFormat(sameDay ? 'HH:mm' : 'dd.MM HH:mm').format(end)}';
}

/// Наряды-допуски: свои, доска «Сейчас идут» и очередь БиОТ.
class WorkPermitsScreen extends StatefulWidget {
  const WorkPermitsScreen({Key? key}) : super(key: key);

  @override
  State<WorkPermitsScreen> createState() => _WorkPermitsScreenState();
}

class _WorkPermitsScreenState extends State<WorkPermitsScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  WorkPermitList _mine = const WorkPermitList(items: []);
  WorkPermitList? _board;
  WorkPermitList? _queue;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchWorkPermits();
      final board = mine.board ? await fetchWorkPermits(scope: 'board') : null;
      final queue = mine.safety ? await fetchWorkPermits(scope: 'queue') : null;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _board = board;
        _queue = queue;
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

  Future<void> _create() async {
    final created = await Get.to<WorkPermit?>(
        () => WorkPermitFormScreen(measures: _mine.measures));
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('wp_sent'.trParams({'id': '${created.id}'}))));
    _load();
  }

  Future<void> _open(WorkPermit item) async {
    await Get.to(() => WorkPermitDetailScreen(permitId: item.id));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <(String, Widget)>[
      if (_queue != null)
        (
          _mine.waiting > 0
              ? '${'wp_tab_queue'.tr} (${_mine.waiting})'
              : 'wp_tab_queue'.tr,
          _list(_queue!.items, 'wp_empty_queue'.tr)
        ),
      if (_board != null)
        ('wp_tab_board'.tr, _list(_board!.items, 'wp_empty_board'.tr)),
      ('wp_tab_mine'.tr, _list(_mine.items, 'wp_empty_mine'.tr)),
    ];
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _problem != null
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : tabs.length == 1
                ? tabs.single.$2
                : TabBarView(children: [for (final t in tabs) t.$2]);
    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'wp_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: _loading || tabs.length == 1
            ? null
            : TabBar(
                isScrollable: tabs.length > 2,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: [for (final t in tabs) Tab(text: t.$1)],
              ),
      ),
      floatingActionButton: _mine.canIssue
          ? FloatingActionButton.extended(
              key: const Key('wp_new'),
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: Text('wp_new'.tr),
            )
          : null,
      body: body,
    );
    return _loading || tabs.length == 1
        ? scaffold
        : DefaultTabController(
            key: ValueKey(tabs.length), length: tabs.length, child: scaffold);
  }

  Widget _list(List<WorkPermit> items, String empty) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(empty,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.mutedColor)),
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 8, bottom: 88),
              itemCount: items.length,
              itemBuilder: (_, i) => _row(items[i]),
            ),
    );
  }

  Widget _row(WorkPermit item) {
    final alarm = item.overdue || item.expired;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: item.status == 'open' || alarm
            ? Border(
                left: BorderSide(
                    color: alarm
                        ? const Color(0xFFC62828)
                        : workPermitColor(item.status),
                    width: 3))
            : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(item.place,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  WorkPermitChip(status: item.status),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  'wp_kind_${item.kind}'.tr,
                  '№${item.id}',
                  workPermitSpan(item),
                ].where((s) => s.isNotEmpty).join(' · '),
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
              const SizedBox(height: 4),
              Text(item.work, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (item.performer != null)
                Text(item.performer!.short,
                    style: TextStyle(fontSize: 12, color: context.mutedColor)),
              if (alarm)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(item.overdue ? 'wp_overdue'.tr : 'wp_expired'.tr,
                      style: TextStyle(
                          fontSize: 12,
                          color: context.readable(const Color(0xFFC62828)))),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
