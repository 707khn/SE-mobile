import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/inspection_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'inspection_detail_screen.dart';
import 'inspection_form_screen.dart';
import 'repair_requests_screen.dart' show repairDowntimeLabel;

Color inspectionStatusColor(String status) => switch (status) {
      'waiting_otk' || 'waiting_vp' => const Color(0xFF1565C0),
      'checking_otk' || 'checking_vp' => const Color(0xFFE65100),
      'accepted' => const Color(0xFF2E7D32),
      'returned' => const Color(0xFFC62828),
      _ => const Color(0xFF757575),
    };

class InspectionStatusChip extends StatelessWidget {
  const InspectionStatusChip({Key? key, required this.status})
      : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(inspectionStatusColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('insp_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Предъявление продукции: свои партии, а у ОТК, ВП и начальника ОП —
/// ещё и очередь приёмки.
class InspectionsScreen extends StatefulWidget {
  const InspectionsScreen({Key? key}) : super(key: key);

  @override
  State<InspectionsScreen> createState() => _InspectionsScreenState();
}

class _InspectionsScreenState extends State<InspectionsScreen> {
  bool _loading = true;
  bool _failed = false;
  LoadProblem? _problem;
  InspectionList _mine = const InspectionList(items: []);
  InspectionList? _queue;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchInspections();
      final queue = mine.staff ? await fetchInspections(queue: true) : null;
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
    final created =
        await Get.to<Inspection?>(() => const InspectionFormScreen());
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('it_sent'.trParams({'id': '${created.id}'}))));
    _load();
  }

  Future<void> _open(Inspection item) async {
    await Get.to(() => InspectionDetailScreen(inspectionId: item.id));
    if (mounted) _load();
  }

  int _count(InspectionList list, String stage) =>
      (list.open['waiting_$stage'] ?? 0) + (list.open['checking_$stage'] ?? 0);

  /// Сколько ждёт именно того, кто смотрит: ОТК — своё, ВП — своё.
  int _waitingForMe(InspectionList list) {
    var n = 0;
    if (list.otk) n += list.open['waiting_otk'] ?? 0;
    if (list.vp) n += list.open['waiting_vp'] ?? 0;
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _failed
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : queue == null
                ? _list(_mine.items, 'insp_empty_mine'.tr)
                : TabBarView(children: [
                    Column(children: [
                      Container(
                        key: const Key('insp_counts'),
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        color: context.accentColor.withOpacity(0.08),
                        child: Text(
                          'insp_counts'.trParams({
                            'otk': '${_count(queue, 'otk')}',
                            'vp': '${_count(queue, 'vp')}',
                          }),
                          style: TextStyle(color: context.accentColor),
                        ),
                      ),
                      Expanded(
                          child: _list(queue.items, 'insp_empty_queue'.tr,
                              staff: true)),
                    ]),
                    _list(_mine.items, 'insp_empty_mine'.tr),
                  ]);

    final waiting = queue == null ? 0 : _waitingForMe(queue);
    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'insp_title'.tr, color: Colors.white),
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
                      text: waiting > 0
                          ? '${'it_queue'.tr} ($waiting)'
                          : 'it_queue'.tr),
                  Tab(text: 'it_mine'.tr),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text('insp_new'.tr),
      ),
      body: body,
    );
    return queue == null
        ? scaffold
        : DefaultTabController(length: 2, child: scaffold);
  }

  Widget _list(List<Inspection> items, String empty, {bool staff = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.fact_check_outlined,
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
              itemBuilder: (_, i) => _row(items[i], staff),
            ),
    );
  }

  Widget _row(Inspection item, bool staff) {
    final when = item.createdAt == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(item.createdAt!);
    final hours = item.waitingHours(DateTime.now());
    final waitingMine = (item.status == 'waiting_otk' && _queue?.otk == true) ||
        (item.status == 'waiting_vp' && _queue?.vp == true);
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: (staff && waitingMine) || (!staff && item.status == 'returned')
            ? Border(
                left: BorderSide(
                    color: inspectionStatusColor(item.status), width: 3))
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
              Icon(Icons.fact_check_outlined, color: context.mutedColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                              '№${item.id} · ${item.product} — ${'insp_pcs'.trParams({'n': '${item.quantity}'})}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                        InspectionStatusChip(status: item.status),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        item.place,
                        if (item.orderNo.isNotEmpty) item.orderNo,
                        if (item.needsVp) 'insp_vp_short'.tr,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        when,
                        if (staff && item.author != null) item.author!.short,
                        if (hours != null)
                          'insp_waiting'
                              .trParams({'time': repairDowntimeLabel(hours)}),
                        if (item.returns > 0)
                          'insp_returns'.trParams({'n': '${item.returns}'}),
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
