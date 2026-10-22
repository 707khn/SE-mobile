import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/purchase_request.dart';
import '../utils/api.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../utils/secure_storage_helper.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'purchase_detail_screen.dart';
import 'purchase_form_screen.dart';

Color purchaseStageColor(String status) => switch (status) {
      'new' => const Color(0xFF1565C0),
      'delivered' => const Color(0xFF2E7D32),
      'rejected' => const Color(0xFFC62828),
      'cancelled' => const Color(0xFF757575),
      _ => const Color(0xFFE65100),
    };

class PurchaseStageChip extends StatelessWidget {
  const PurchaseStageChip({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(purchaseStageColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('purch_stage_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Шесть отрезков: сколько этапов закупка уже прошла.
class PurchaseProgress extends StatelessWidget {
  const PurchaseProgress({Key? key, required this.item}) : super(key: key);

  final Purchase item;

  @override
  Widget build(BuildContext context) {
    final reached = item.stageIndex;
    final color = context.readable(purchaseStageColor(item.status));
    return Row(
      children: [
        for (var i = 0; i < purchaseStages.length; i++) ...[
          if (i > 0) const SizedBox(width: 3),
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color: i <= reached ? color : context.hairlineColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Заявки на закупку: свои, а у ДМТО — очередь и то, что на мне.
class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({Key? key}) : super(key: key);

  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  bool _loading = true;
  bool _failed = false;
  LoadProblem? _problem;
  PurchaseList _mine = const PurchaseList(items: []);
  PurchaseList? _queue;
  String? _me;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchPurchases();
      final queue = mine.staff ? await fetchPurchases(queue: true) : null;
      final me = queue == null
          ? null
          : await SecureStorageHelper.instance.getEmployeeId() ??
              await employeeIdFromServer();
      if (!mounted) return;
      setState(() {
        _me = me;
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
    final created = await Get.to<Purchase?>(() => const PurchaseFormScreen());
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('it_sent'.trParams({'id': '${created.id}'}))));
    _load();
  }

  Future<void> _open(Purchase item) async {
    await Get.to(() => PurchaseDetailScreen(purchaseId: item.id));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    final open = queue?.open ?? const {};
    final work = (open['accepted'] ?? 0) +
        (open['sourcing'] ?? 0) +
        (open['contract'] ?? 0);
    final assigned = queue == null
        ? const <Purchase>[]
        : queue.items
            .where((i) => i.isOpen && i.assignee != null && i.assignee!.id == _me)
            .toList();
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _failed
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : queue == null
                ? _list(_mine.items, 'purch_empty_mine'.tr)
                : TabBarView(children: [
                    Column(children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        color: context.accentColor.withOpacity(0.08),
                        child: Text(
                          'purch_counts'.trParams({
                            'new': '${open['new'] ?? 0}',
                            'work': '$work',
                            'transit': '${open['in_transit'] ?? 0}',
                          }),
                          style: TextStyle(color: context.accentColor),
                        ),
                      ),
                      Expanded(
                          child: _list(queue.items, 'purch_empty_queue'.tr,
                              staff: true)),
                    ]),
                    _list(assigned, 'purch_empty_queue'.tr,
                        staff: true),
                    _list(_mine.items, 'purch_empty_mine'.tr),
                  ]);

    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'purch_title'.tr, color: Colors.white),
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
                      text: (open['new'] ?? 0) > 0
                          ? '${'purch_queue'.tr} (${open['new']})'
                          : 'purch_queue'.tr),
                  Tab(
                      text: queue.mineOpen > 0
                          ? '${'purch_assigned'.tr} (${queue.mineOpen})'
                          : 'purch_assigned'.tr),
                  Tab(text: 'purch_mine'.tr),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text('purch_new'.tr),
      ),
      body: body,
    );
    return queue == null
        ? scaffold
        : DefaultTabController(length: 3, child: scaffold);
  }

  Widget _list(List<Purchase> items, String empty, {bool staff = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.shopping_cart_outlined,
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

  Widget _row(Purchase item, bool staff) {
    final first = item.lines.isEmpty ? '' : item.lines.first.name;
    final more = item.lines.length > 1 ? ' +${item.lines.length - 1}' : '';
    final who = staff ? item.author?.short : item.assignee?.short;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: item.urgent && item.isOpen
            ? const Border(left: BorderSide(color: Color(0xFFC62828), width: 3))
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
                    child: Text('№${item.id} · ${item.purpose}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  PurchaseStageChip(status: item.status),
                ],
              ),
              const SizedBox(height: 4),
              Text('$first$more',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
              if (item.stageIndex >= 0) ...[
                const SizedBox(height: 8),
                PurchaseProgress(item: item),
              ],
              const SizedBox(height: 6),
              Text(
                [
                  if (who != null && who.isNotEmpty) who,
                  if (item.urgent) 'purch_urgent'.tr,
                  if (item.neededBy != null)
                    'purch_needed_by_date'.trParams(
                        {'date': DateFormat('dd.MM').format(item.neededBy!)}),
                  if (item.eta != null && item.isOpen)
                    'purch_eta'.trParams(
                        {'date': DateFormat('dd.MM').format(item.eta!)}),
                  if (item.stale) 'purch_stale'.tr,
                ].join(' · '),
                style: TextStyle(
                    fontSize: 11,
                    color: item.stale
                        ? context.readable(const Color(0xFFE65100))
                        : context.mutedColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
