import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/order_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'order_detail_screen.dart';
import 'order_form_screen.dart';

/// «Приказ №45-П от 20.10.2026».
String orderHeading(OrderDoc item) => [
      'ord_kind_${item.kind}'.tr,
      if (item.number.isNotEmpty)
        'ord_number'.trParams({'number': item.number}),
      if (item.docDate != null)
        'ord_from'
            .trParams({'date': DateFormat('dd.MM.yyyy').format(item.docDate!)}),
    ].join(' ');

/// Приказы к ознакомлению, прочитанные, а у делопроизводства — разосланные.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({Key? key}) : super(key: key);

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  bool _loading = true;
  bool _failed = false;
  LoadProblem? _problem;
  OrderList _mine = const OrderList(items: []);
  OrderList? _published;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchOrders();
      final published =
          mine.publisher ? await fetchOrders(published: true) : null;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _published = published;
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

  Future<void> _open(OrderDoc item) async {
    await Get.to(() => OrderDetailScreen(orderId: item.id));
    if (mounted) _load();
  }

  Future<void> _create() async {
    final created = await Get.to<OrderDoc>(() => const OrderFormScreen());
    if (!mounted) return;
    _load();
    if (created != null) _open(created);
  }

  @override
  Widget build(BuildContext context) {
    final published = _published;
    final pending = _mine.items.where((o) => !o.isAcked).toList();
    final read = _mine.items.where((o) => o.isAcked).toList();
    final tabs = [
      Tab(
          text: _mine.pending > 0
              ? '${'ord_tab_pending'.tr} (${_mine.pending})'
              : 'ord_tab_pending'.tr),
      Tab(text: 'ord_tab_read'.tr),
      if (published != null) Tab(text: 'ord_tab_published'.tr),
    ];
    return DefaultTabController(
      // Ключ — чтобы после первой загрузки контроллер пересоздался с третьей
      // вкладкой.
      key: ValueKey(tabs.length),
      length: tabs.length,
      child: Scaffold(
        backgroundColor: context.pageColor,
        appBar: AppBar(
          title: BigText(content: 'ord_title'.tr, color: Colors.white),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'refresh'.tr,
              onPressed: _loading ? null : _load,
            ),
          ],
          bottom: TabBar(
            isScrollable: tabs.length > 2,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: tabs,
          ),
        ),
        floatingActionButton: published == null
            ? null
            : FloatingActionButton.extended(
                key: const Key('ord_new'),
                onPressed: _create,
                icon: const Icon(Icons.campaign_outlined),
                label: Text('ord_new'.tr),
              ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _failed
                ? LoadErrorView(problem: _problem, onRetry: _load)
                : TabBarView(children: [
                    _list(pending, 'ord_empty_pending'.tr),
                    _list(read, 'ord_empty_read'.tr),
                    if (published != null)
                      _list(published.items, 'ord_empty_published'.tr,
                          publisher: true),
                  ]),
      ),
    );
  }

  Widget _list(List<OrderDoc> items, String empty, {bool publisher = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.gavel_outlined, size: 56, color: context.mutedColor),
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
              itemBuilder: (_, i) => _row(items[i], publisher),
            ),
    );
  }

  Widget _row(OrderDoc item, bool publisher) {
    final overdue = !publisher && item.overdue(DateTime.now());
    final pending = !publisher && !item.isAcked;
    final accent = overdue ? const Color(0xFFC62828) : const Color(0xFF1565C0);
    final meta = <String>[
      if (publisher && item.total != null)
        'ord_progress'.trParams(
            {'acked': '${item.acked ?? 0}', 'total': '${item.total}'}),
      if (publisher && item.withdrawn) 'ord_withdrawn'.tr,
      if (item.isAcked && !publisher)
        'ord_acked_at'.trParams(
            {'date': DateFormat('dd.MM.yyyy HH:mm').format(item.ackedAt!)}),
      if (pending && item.dueDate != null)
        overdue
            ? 'ord_overdue'.tr
            : 'ord_due'
                .trParams({'date': DateFormat('dd.MM').format(item.dueDate!)}),
    ];
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border:
            pending ? Border(left: BorderSide(color: accent, width: 3)) : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(orderHeading(item),
                  style: TextStyle(fontSize: 12, color: context.mutedColor)),
              const SizedBox(height: 2),
              Text(item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              if (meta.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(meta.join(' · '),
                    style: TextStyle(
                        fontSize: 12,
                        color: overdue
                            ? context.readable(accent)
                            : context.mutedColor)),
              ],
              if (publisher && (item.total ?? 0) > 0) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: (item.acked ?? 0) / item.total!,
                    minHeight: 4,
                    backgroundColor: context.hairlineColor,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
