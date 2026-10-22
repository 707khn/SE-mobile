import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/hazard_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'hazard_detail_screen.dart';
import 'hazard_form_screen.dart';

Color hazardStatusColor(String status) => switch (status) {
      'new' => const Color(0xFFC62828),
      'in_work' => const Color(0xFFE65100),
      'resolved' => const Color(0xFF2E7D32),
      _ => const Color(0xFF757575),
    };

IconData hazardIcon(String category) => switch (category) {
      'spill' => Icons.water_drop_outlined,
      'electrical' => Icons.electrical_services,
      'equipment' => Icons.precision_manufacturing_outlined,
      'fire' => Icons.local_fire_department_outlined,
      'height' => Icons.stairs_outlined,
      'near_miss' => Icons.personal_injury_outlined,
      _ => Icons.report_problem_outlined,
    };

class HazardStatusChip extends StatelessWidget {
  const HazardStatusChip({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(hazardStatusColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('hz_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Свои сообщения (и анонимные с этого телефона), а у БиОТ — очередь.
class HazardsScreen extends StatefulWidget {
  const HazardsScreen({Key? key}) : super(key: key);

  @override
  State<HazardsScreen> createState() => _HazardsScreenState();
}

class _HazardsScreenState extends State<HazardsScreen> {
  bool _loading = true;
  bool _failed = false;
  LoadProblem? _problem;
  List<Hazard> _mine = const [];
  HazardList? _queue;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final own = await fetchHazards();
      final anonymous = await trackHazards(await savedHazardTracks());
      final queue = own.staff ? await fetchHazards(queue: true) : null;
      final mine = [...own.items, ...anonymous]..sort((a, b) =>
          (b.createdAt ?? DateTime(2000))
              .compareTo(a.createdAt ?? DateTime(2000)));
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

  Future<void> _open(Hazard item) async {
    // Своё анонимное сервер отдаёт только по ключу; БиОТ видит его и так.
    await Get.to(() => HazardDetailScreen(
        hazardId: item.id, anonymous: item.anonymous && _queue == null));
    if (mounted) _load();
  }

  Future<void> _create() async {
    final created = await Get.to<Hazard>(() => const HazardFormScreen());
    if (!mounted) return;
    _load();
    if (created != null && created.anonymous && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('hz_sent_anonymous'.tr)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _failed
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : queue == null
                ? _list(_mine, 'hz_empty_mine'.tr)
                : TabBarView(children: [
                    _list(queue.items, 'hz_empty_queue'.tr, staff: true),
                    _list(_mine, 'hz_empty_mine'.tr),
                  ]);
    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'hz_title'.tr, color: Colors.white),
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
                      text: queue.fresh > 0
                          ? '${'hz_tab_queue'.tr} (${queue.fresh})'
                          : 'hz_tab_queue'.tr),
                  Tab(text: 'hz_tab_mine'.tr),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('hz_new'),
        onPressed: _create,
        backgroundColor: const Color(0xFFC62828),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.report_problem_outlined),
        label: Text('hz_new'.tr),
      ),
      body: body,
    );
    return queue == null
        ? scaffold
        : DefaultTabController(length: 2, child: scaffold);
  }

  Widget _list(List<Hazard> items, String empty, {bool staff = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.health_and_safety_outlined,
                    size: 56, color: context.mutedColor),
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
              itemBuilder: (_, i) => _row(items[i], staff),
            ),
    );
  }

  Widget _row(Hazard item, bool staff) {
    final when = item.createdAt == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(item.createdAt!);
    final color = hazardStatusColor(item.status);
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: item.isOpen
            ? Border(left: BorderSide(color: color, width: 3))
            : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(hazardIcon(item.category),
                  color: item.urgent && item.isOpen
                      ? context.readable(const Color(0xFFC62828))
                      : context.mutedColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                              '${item.urgent ? '⚠ ' : ''}'
                              '${'hz_cat_${item.category}'.tr}',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                        HazardStatusChip(status: item.status),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(item.place,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(
                      [
                        when,
                        if (item.anonymous) 'hz_anonymous_badge'.tr,
                        if (staff && item.author != null) item.author!.short,
                      ].where((s) => s.isNotEmpty).join(' · '),
                      style: TextStyle(fontSize: 11, color: context.mutedColor),
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
