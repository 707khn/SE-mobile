import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'assignment_detail_screen.dart';
import 'assignment_form_screen.dart';

Color assignmentStatusColor(String status) => switch (status) {
      'new' => const Color(0xFF1565C0),
      'in_progress' => const Color(0xFFE65100),
      'done' => const Color(0xFF6A1B9A),
      'closed' => const Color(0xFF2E7D32),
      _ => const Color(0xFF757575),
    };

const _overdueColor = Color(0xFFC62828);

class AssignmentStatusChip extends StatelessWidget {
  const AssignmentStatusChip({Key? key, required this.status})
      : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(assignmentStatusColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('asg_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// «до 20.01» или «Просрочено · до 20.01».
String assignmentDueLabel(Assignment item) {
  final due =
      'asg_due'.trParams({'date': DateFormat('dd.MM').format(item.dueDate)});
  return item.overdue ? '${'asg_overdue'.tr} · $due' : due;
}

/// Поручения: мне и те, что я дал.
class AssignmentsScreen extends StatefulWidget {
  const AssignmentsScreen({Key? key}) : super(key: key);

  @override
  State<AssignmentsScreen> createState() => _AssignmentsScreenState();
}

class _AssignmentsScreenState extends State<AssignmentsScreen> {
  bool _loading = true;
  bool _failed = false;
  LoadProblem? _problem;
  AssignmentList _mine = const AssignmentList(items: []);
  AssignmentList _given = const AssignmentList(items: []);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchAssignments();
      final given = await fetchAssignments(given: true);
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _given = given;
        _failed = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _problem = problemOfAny(e);
        _loading = false;
      });
    }
  }

  Future<void> _open(Assignment item) async {
    await Get.to(() => AssignmentDetailScreen(assignmentId: item.id));
    if (mounted) _load();
  }

  Future<void> _create() async {
    final created =
        await Get.to<List<Assignment>>(() => const AssignmentFormScreen());
    if (!mounted) return;
    _load();
    if (created != null && created.length == 1) _open(created.single);
  }

  String _tab(String label, int count) => count > 0 ? '$label ($count)' : label;

  @override
  Widget build(BuildContext context) {
    final counts = _mine.counts;
    final canAssign = _mine.canAssign;
    final showGiven = canAssign || _given.items.isNotEmpty;
    final tabs = [
      Tab(text: _tab('asg_tab_mine'.tr, counts.mineOpen)),
      // У поручившего в скобках — отчёты, которые ждут его проверки.
      if (showGiven) Tab(text: _tab('asg_tab_given'.tr, counts.givenDone)),
    ];
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _failed
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : showGiven
                ? TabBarView(children: [
                    _list(_mine.items, 'asg_empty_mine'.tr, given: false),
                    _list(_given.items, 'asg_empty_given'.tr, given: true),
                  ])
                : _list(_mine.items, 'asg_empty_mine'.tr, given: false);
    return DefaultTabController(
      key: ValueKey(tabs.length),
      length: tabs.length,
      child: Scaffold(
        backgroundColor: context.pageColor,
        appBar: AppBar(
          title: BigText(content: 'asg_title'.tr, color: Colors.white),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'refresh'.tr,
              onPressed: _loading ? null : _load,
            ),
          ],
          bottom: showGiven
              ? TabBar(
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  indicatorColor: Colors.white,
                  tabs: tabs,
                )
              : null,
        ),
        floatingActionButton: canAssign
            ? FloatingActionButton.extended(
                key: const Key('asg_new'),
                onPressed: _create,
                icon: const Icon(Icons.add_task),
                label: Text('asg_new'.tr),
              )
            : null,
        body: body,
      ),
    );
  }

  Widget _list(List<Assignment> items, String empty, {required bool given}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.task_alt, size: 56, color: context.mutedColor),
                const SizedBox(height: 12),
                Text(empty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.mutedColor)),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 8, bottom: 88),
              itemCount: items.length,
              itemBuilder: (_, i) => _row(items[i], given),
            ),
    );
  }

  Widget _row(Assignment item, bool given) {
    // Ждёт этого человека: исполнителя — открытое, поручившего — отчёт.
    final waiting = given ? item.status == 'done' : item.isOpen;
    final edge =
        item.overdue ? _overdueColor : assignmentStatusColor(item.status);
    final who = given ? item.assignee : item.author;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: waiting || item.overdue
            ? Border(left: BorderSide(color: edge, width: 3))
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.important)
                    Padding(
                      padding: const EdgeInsets.only(right: 4, top: 1),
                      child: Icon(Icons.priority_high,
                          size: 16, color: context.readable(_overdueColor)),
                    ),
                  Expanded(
                    child: Text(item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  AssignmentStatusChip(status: item.status),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (!item.isClosed) assignmentDueLabel(item),
                  if (who != null) who.short,
                ].join(' · '),
                style: TextStyle(
                    fontSize: 12,
                    color: item.overdue
                        ? context.readable(_overdueColor)
                        : context.mutedColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
