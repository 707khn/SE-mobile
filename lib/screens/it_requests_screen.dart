import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/it_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'it_request_detail_screen.dart';
import 'it_request_form_screen.dart';

/// Цвет и подпись статуса — одни на списке и на экране заявки.
Color itStatusColor(String status) => switch (status) {
      'new' => const Color(0xFF1565C0),
      'in_progress' => const Color(0xFFE65100),
      'done' => const Color(0xFF2E7D32),
      'rejected' => const Color(0xFFC62828),
      _ => const Color(0xFF757575),
    };

IconData itCategoryIcon(String category) => switch (category) {
      'printer' => Icons.print_outlined,
      'computer' => Icons.computer_outlined,
      'network' => Icons.wifi_outlined,
      'phone' => Icons.phone_outlined,
      'software' => Icons.apps_outlined,
      'account' => Icons.key_outlined,
      _ => Icons.help_outline,
    };

class ItStatusChip extends StatelessWidget {
  const ItStatusChip({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(itStatusColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('it_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Заявки в ОИТиС: свои, а у сотрудников ОИТиС — ещё и очередь.
///
/// Кто в ОИТиС, решает сервер (по подразделению) и сообщает в ответе:
/// приложению по должности этого не угадать — там и начальник, и техник,
/// и инженер-программист.
class ItRequestsScreen extends StatefulWidget {
  const ItRequestsScreen({Key? key}) : super(key: key);

  @override
  State<ItRequestsScreen> createState() => _ItRequestsScreenState();
}

class _ItRequestsScreenState extends State<ItRequestsScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  bool _failed = false;
  ItRequestList _mine = const ItRequestList(items: []);
  ItRequestList? _queue;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchItRequests();
      final queue = mine.itStaff ? await fetchItRequests(queue: true) : null;
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
    final created = await Get.to<ItRequest?>(() => const ItRequestFormScreen());
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('it_sent'.trParams({'id': '${created.id}'}))));
    _load();
  }

  Future<void> _open(ItRequest item) async {
    await Get.to(() => ItRequestDetailScreen(
          requestId: item.id,
          staff: _mine.itStaff,
        ));
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
                ? _list(_mine.items, 'it_empty_mine'.tr)
                : TabBarView(children: [
                    _queueList(queue),
                    _list(_mine.items, 'it_empty_mine'.tr),
                  ]);

    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'it_title'.tr, color: Colors.white),
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
        label: Text('it_new'.tr),
      ),
      body: body,
    );
    return queue == null
        ? scaffold
        : DefaultTabController(length: 2, child: scaffold);
  }

  Widget _queueList(ItRequestList queue) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          color: context.accentColor.withOpacity(0.08),
          child: Text(
            'it_queue_counts'.trParams({
              'new': '${queue.openNew}',
              'work': '${queue.openInProgress}',
            }),
            style: TextStyle(color: context.accentColor),
          ),
        ),
        Expanded(child: _list(queue.items, 'it_empty_queue'.tr, staff: true)),
      ],
    );
  }

  Widget _list(List<ItRequest> items, String empty, {bool staff = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.support_agent, size: 56, color: context.mutedColor),
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

  Widget _row(ItRequest item, bool staff) {
    final when = item.createdAt == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(item.createdAt!);
    final who = staff ? item.author?.short : item.assignee?.short;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        // Новые в очереди видно, не читая.
        border: staff && item.status == 'new'
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
              Icon(itCategoryIcon(item.category), color: context.mutedColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '№${item.id} · ${'it_room'.tr} ${item.room}',
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ),
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
                        if (who != null && who.isNotEmpty) who,
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
