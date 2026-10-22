import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/approval_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'approval_detail_screen.dart';
import 'approval_form_screen.dart';
import 'repair_requests_screen.dart' show repairDowntimeLabel;

Color approvalStatusColor(String status) => switch (status) {
      'on_route' => const Color(0xFF1565C0),
      'approved' => const Color(0xFF2E7D32),
      'returned' => const Color(0xFFC62828),
      _ => const Color(0xFF757575),
    };

const approvalStaleColor = Color(0xFFE65100);

IconData approvalKindIcon(String kind) => switch (kind) {
      'contract' => Icons.handshake_outlined,
      'memo' => Icons.description_outlined,
      _ => Icons.article_outlined,
    };

class ApprovalStatusChip extends StatelessWidget {
  const ApprovalStatusChip({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(approvalStatusColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('appr_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Листы согласования: что ждёт моей подписи и всё, где я автор или в
/// маршруте.
class ApprovalsScreen extends StatefulWidget {
  const ApprovalsScreen({Key? key}) : super(key: key);

  @override
  State<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

class _ApprovalsScreenState extends State<ApprovalsScreen> {
  bool _loading = true;
  bool _failed = false;
  LoadProblem? _problem;
  ApprovalList _list = const ApprovalList(items: []);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await fetchApprovals();
      if (!mounted) return;
      setState(() {
        _list = list;
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

  Future<void> _create() async {
    final created = await Get.to<Approval?>(() => const ApprovalFormScreen());
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('it_sent'.trParams({'id': '${created.id}'}))));
    _load();
  }

  Future<void> _open(Approval item) async {
    await Get.to(() => ApprovalDetailScreen(approvalId: item.id));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final todo = _list.items.where((i) => i.myTurn).toList()
      // Дольше всех лежащее — первым.
      ..sort((a, b) => (a.stepSince ?? DateTime(2100))
          .compareTo(b.stepSince ?? DateTime(2100)));
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: context.pageColor,
        appBar: AppBar(
          title: BigText(content: 'appr_title'.tr, color: Colors.white),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'refresh'.tr,
              onPressed: _loading ? null : _load,
            ),
          ],
          bottom: TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [
              Tab(
                  text: _list.todo > 0
                      ? '${'appr_todo'.tr} (${_list.todo})'
                      : 'appr_todo'.tr),
              Tab(text: 'appr_all'.tr),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _create,
          icon: const Icon(Icons.add),
          label: Text('appr_new'.tr),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _failed
                ? LoadErrorView(problem: _problem, onRetry: _load)
                : TabBarView(children: [
                    _listView(todo, 'appr_empty_todo'.tr),
                    _listView(_list.items, 'appr_empty_all'.tr),
                  ]),
      ),
    );
  }

  Widget _listView(List<Approval> items, String empty) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.approval_outlined,
                    size: 56, color: context.mutedColor),
                const SizedBox(height: 12),
                Text(empty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.mutedColor)),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              itemCount: items.length,
              itemBuilder: (_, i) => _row(items[i]),
            ),
    );
  }

  Widget _row(Approval item) {
    final now = DateTime.now();
    final when = item.createdAt == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(item.createdAt!);
    final hours = item.waitingHours(now);
    final stale = item.isStale(now);
    final highlight = item.myTurn || (item.isAuthor && item.status == 'returned');
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: highlight
            ? Border(
                left: BorderSide(
                    color: approvalStatusColor(item.status), width: 3))
            : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(approvalKindIcon(item.kind), color: context.mutedColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('№${item.id} · ${item.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                        ApprovalStatusChip(status: item.status),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        if (item.current != null && !item.myTurn)
                          'appr_at'.trParams({'name': item.current!.short}),
                        if (item.myTurn && item.author != null)
                          item.author!.short,
                        if (item.steps.isNotEmpty)
                          'appr_progress'.trParams({
                            'done': '${item.approvedCount}',
                            'total': '${item.steps.length}',
                          }),
                        if (item.docNumber.isNotEmpty) item.docNumber,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        when,
                        if (hours != null)
                          'appr_waiting'
                              .trParams({'time': repairDowntimeLabel(hours)}),
                        if (stale) 'appr_stale'.tr,
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style: TextStyle(
                          fontSize: 11,
                          color: stale
                              ? context.readable(approvalStaleColor)
                              : context.mutedColor,
                          fontWeight: stale ? FontWeight.w600 : null),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
