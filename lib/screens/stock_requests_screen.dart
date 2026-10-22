import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/stock_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'stock_request_detail_screen.dart';
import 'stock_request_form_screen.dart';

Color stockStatusColor(String status) => switch (status) {
      'new' => const Color(0xFF1565C0),
      'in_progress' => const Color(0xFFE65100),
      'ready' => const Color(0xFF2E7D32),
      'issued' => const Color(0xFF546E7A),
      'rejected' => const Color(0xFFC62828),
      _ => const Color(0xFF757575),
    };

class StockStatusChip extends StatelessWidget {
  const StockStatusChip({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(stockStatusColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('stock_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Заявки на ТМЦ: свои, а у Службы учёта ТМЦ — ещё и очередь склада.
class StockRequestsScreen extends StatefulWidget {
  const StockRequestsScreen({Key? key}) : super(key: key);

  @override
  State<StockRequestsScreen> createState() => _StockRequestsScreenState();
}

class _StockRequestsScreenState extends State<StockRequestsScreen> {
  bool _loading = true;
  bool _failed = false;
  LoadProblem? _problem;
  StockRequestList _mine = const StockRequestList(items: []);
  StockRequestList? _queue;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchStockRequests();
      final queue = mine.staff ? await fetchStockRequests(queue: true) : null;
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
        await Get.to<StockRequest?>(() => const StockRequestFormScreen());
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('it_sent'.trParams({'id': '${created.id}'}))));
    _load();
  }

  Future<void> _open(StockRequest item) async {
    await Get.to(() => StockRequestDetailScreen(requestId: item.id));
    if (mounted) _load();
  }

  /// Открытые своего склада — наверх: остальное соберут на других.
  List<StockRequest> _sorted(StockRequestList queue) {
    final mine = queue.myWarehouse;
    if (mine == null) return queue.items;
    final items = [...queue.items];
    int rank(StockRequest r) =>
        r.isOpen && (r.warehouse == mine || r.warehouse == null) ? 0 : 1;
    // sort не стабилен — держим порядок сервера через индекс.
    final order = {for (var i = 0; i < items.length; i++) items[i]: i};
    items.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : order[a]!.compareTo(order[b]!);
    });
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _failed
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : queue == null
                ? _list(_mine.items, 'stock_empty_mine'.tr)
                : TabBarView(children: [
                    Column(children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        color: context.accentColor.withOpacity(0.08),
                        child: Text(
                          'stock_queue_counts'.trParams({
                            'new': '${queue.openNew}',
                            'work': '${queue.openInProgress}',
                            'ready': '${queue.openReady}',
                          }),
                          style: TextStyle(color: context.accentColor),
                        ),
                      ),
                      Expanded(
                          child: _list(_sorted(queue), 'stock_empty_queue'.tr,
                              staff: true)),
                    ]),
                    _list(_mine.items, 'stock_empty_mine'.tr),
                  ]);

    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'stock_title'.tr, color: Colors.white),
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
        label: Text('stock_new'.tr),
      ),
      body: body,
    );
    return queue == null
        ? scaffold
        : DefaultTabController(length: 2, child: scaffold);
  }

  Widget _list(List<StockRequest> items, String empty, {bool staff = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.inventory_2_outlined,
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

  Widget _row(StockRequest item, bool staff) {
    final when = item.createdAt == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(item.createdAt!);
    final who = staff ? item.author?.short : item.assignee?.short;
    final first = item.lines.isEmpty ? '' : item.lines.first.name;
    final more = item.lines.length > 1 ? ' +${item.lines.length - 1}' : '';
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: (staff && item.status == 'new') || item.status == 'ready'
            ? Border(
                left: BorderSide(
                    color: stockStatusColor(item.status), width: 3))
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
              Icon(Icons.inventory_2_outlined, color: context.mutedColor),
              const SizedBox(width: 12),
              Expanded(
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
                        StockStatusChip(status: item.status),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('$first$more',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(
                      [
                        when,
                        item.warehouse == null
                            ? 'stock_warehouse_any'.tr
                            : 'stock_warehouse_n'
                                .trParams({'n': '${item.warehouse}'}),
                        if (who != null && who.isNotEmpty) who,
                        if (item.missingCount > 0)
                          'stock_missing_count'
                              .trParams({'count': '${item.missingCount}'}),
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
