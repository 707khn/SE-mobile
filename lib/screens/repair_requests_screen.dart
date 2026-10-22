import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/repair_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'it_requests_screen.dart' show ItStatusChip, itStatusColor;
import 'repair_request_detail_screen.dart';
import 'repair_request_form_screen.dart';

const repairStoppedColor = Color(0xFFC62828);

IconData repairCategoryIcon(String category) => switch (category) {
      'equipment' => Icons.precision_manufacturing_outlined,
      'electric' => Icons.electrical_services_outlined,
      'building' => Icons.door_front_door_outlined,
      'plumbing' => Icons.plumbing_outlined,
      'furniture' => Icons.chair_outlined,
      'vehicle' => Icons.directions_car_outlined,
      _ => Icons.build_outlined,
    };

/// «40 мин», «5 ч», «1 д 3 ч».
String repairDowntimeLabel(double hours) {
  if (hours < 1) {
    return 'repair_unit_min'.trParams({'n': '${(hours * 60).round()}'});
  }
  final whole = hours.round();
  if (whole < 24) return 'repair_unit_h'.trParams({'n': '$whole'});
  final days = whole ~/ 24;
  final rest = whole % 24;
  return rest == 0
      ? 'repair_unit_d'.trParams({'n': '$days'})
      : 'repair_unit_dh'.trParams({'d': '$days', 'h': '$rest'});
}

class RepairStoppedBadge extends StatelessWidget {
  const RepairStoppedBadge({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final color = context.readable(repairStoppedColor);
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('repair_stopped_badge'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w700)),
    );
  }
}

/// Заявки на ремонт: свои, а у службы главного инженера и хозотдела —
/// ещё и очередь своей службы.
class RepairRequestsScreen extends StatefulWidget {
  const RepairRequestsScreen({Key? key}) : super(key: key);

  @override
  State<RepairRequestsScreen> createState() => _RepairRequestsScreenState();
}

class _RepairRequestsScreenState extends State<RepairRequestsScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  bool _failed = false;
  RepairRequestList _mine = const RepairRequestList(items: []);
  RepairRequestList? _queue;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchRepairRequests();
      final queue = mine.staff ? await fetchRepairRequests(queue: true) : null;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _queue = queue;
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
    final created = await Get.to<RepairRequest?>(() =>
        RepairRequestFormScreen(photosAllowed: _mine.photosAllowed));
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('it_sent'.trParams({'id': '${created.id}'}))));
    _load();
  }

  Future<void> _open(RepairRequest item) async {
    await Get.to(() => RepairRequestDetailScreen(requestId: item.id));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _failed
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : queue == null
                ? _list(_mine.items, 'repair_empty_mine'.tr)
                : TabBarView(children: [
                    _queueList(queue),
                    _list(_mine.items, 'repair_empty_mine'.tr),
                  ]);

    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'repair_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: queue == null
            ? null
            : TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: [
                  Tab(
                      text: queue.openNew > 0
                          ? '${'it_queue'.tr} (${queue.openNew})'
                          : 'it_queue'.tr),
                  Tab(text: 'it_mine'.tr),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text('repair_new'.tr),
      ),
      body: body,
    );
    return queue == null
        ? scaffold
        : DefaultTabController(length: 2, child: scaffold);
  }

  Widget _queueList(RepairRequestList queue) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          color: context.accentColor.withOpacity(0.08),
          child: Text(
            'repair_queue_counts'.trParams({
              'new': '${queue.openNew}',
              'work': '${queue.openInProgress}',
              'stopped': '${queue.openStopped}',
            }),
            style: TextStyle(color: context.accentColor),
          ),
        ),
        Expanded(
            child: _list(queue.items, 'repair_empty_queue'.tr,
                staff: true, top: queue.top)),
      ],
    );
  }

  Widget _list(List<RepairRequest> items, String empty,
      {bool staff = false, List<RepairTop> top = const []}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty && top.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.build_outlined,
                    size: 56, color: context.mutedColor),
                const SizedBox(height: 12),
                Text(empty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.mutedColor)),
              ],
            )
          : ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              children: [
                for (final item in items) _row(item, staff),
                if (top.isNotEmpty) _topCard(top),
              ],
            ),
    );
  }

  /// Что ломается чаще и стоит дольше — главному инженеру, под очередью.
  Widget _topCard(List<RepairTop> top) {
    return Container(
      margin: EdgeInsets.fromLTRB(
          Dimensions.width20, 16, Dimensions.width20, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('repair_top'.tr,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final row in top)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                      child: Text(row.equipment,
                          style: const TextStyle(fontSize: 13))),
                  Text(
                    'repair_top_row'.trParams({
                      'count': '${row.count}',
                      'time': repairDowntimeLabel(row.downtimeHours),
                    }),
                    style: TextStyle(fontSize: 12, color: context.mutedColor),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(RepairRequest item, bool staff) {
    final when = item.createdAt == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(item.createdAt!);
    final who = staff ? item.author?.short : item.assignee?.short;
    final standing = item.stopped && item.isOpen;
    final title = item.equipment.isEmpty
        ? '№${item.id} · ${item.place}'
        : '№${item.id} · ${item.equipment}';
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: standing
            ? const Border(
                left: BorderSide(color: repairStoppedColor, width: 3))
            : staff && item.status == 'new'
                ? Border(
                    left: BorderSide(
                        color: itStatusColor(item.status), width: 3))
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
              Icon(repairCategoryIcon(item.category),
                  color: context.mutedColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                        if (standing) const RepairStoppedBadge(),
                        ItStatusChip(status: item.status),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(item.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(
                      [
                        when,
                        if (item.equipment.isNotEmpty) item.place,
                        if (who != null && who.isNotEmpty) who,
                        if (item.downtimeHours != null)
                          (standing ? 'repair_standing' : 'repair_stood')
                              .trParams({
                            'time': repairDowntimeLabel(item.downtimeHours!)
                          }),
                        if (item.photoCount > 0) '📷 ${item.photoCount}',
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style:
                          TextStyle(fontSize: 11, color: context.mutedColor),
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
