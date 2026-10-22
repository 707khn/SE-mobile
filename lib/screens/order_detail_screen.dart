import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/order_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../utils/open_external.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'order_report_screen.dart';
import 'orders_screen.dart';

/// Текст приказа и кнопка «Ознакомлен»; издающему — отчёт, напоминание,
/// отзыв.
class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({Key? key, required this.orderId}) : super(key: key);

  final int orderId;

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  OrderDoc? _item;
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final item = await fetchOrder(widget.orderId);
      if (!mounted) return;
      setState(() {
        _item = item;
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

  Future<void> _act(String action) async {
    if (action == 'withdraw') {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text('ord_withdraw_confirm'.tr),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('cancel'.tr)),
            TextButton(
                key: const Key('ord_withdraw_ok'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text('ord_withdraw'.tr)),
          ],
        ),
      );
      if (sure != true || !mounted) return;
    }
    setState(() => _busy = true);
    final result = await orderAction(widget.orderId, action);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.item != null) _item = result.item;
    });
    final messenger = ScaffoldMessenger.of(context);
    if (result.ok) {
      if (result.reminded != null) {
        messenger.showSnackBar(SnackBar(
            content: Text(
                'ord_reminded'.trParams({'count': '${result.reminded}'}))));
        _load();
      } else if (action == 'ack') {
        messenger.showSnackBar(SnackBar(content: Text('ord_ack_done'.tr)));
      }
      return;
    }
    final code = result.error;
    final key = 'ord_err_$code';
    messenger.showSnackBar(SnackBar(
        content:
            Text(code != null && key.tr != key ? key.tr : 'it_err_failed'.tr)));
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: item == null ? 'ord_title'.tr : 'ord_kind_${item.kind}'.tr,
            color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading && item == null
          ? const Center(child: CircularProgressIndicator())
          : item == null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                    children: [
                      Text(orderHeading(item),
                          style: TextStyle(
                              fontSize: 13, color: context.mutedColor)),
                      const SizedBox(height: 4),
                      Text(item.title,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                      if (item.withdrawn) ...[
                        const SizedBox(height: 8),
                        Text('ord_withdrawn'.tr,
                            style: TextStyle(
                                color:
                                    context.readable(const Color(0xFFC62828)))),
                      ],
                      if (item.dueDate != null && !item.isAcked) ...[
                        const SizedBox(height: 8),
                        Text(
                            item.overdue(DateTime.now())
                                ? 'ord_overdue'.tr
                                : 'ord_due'.trParams({
                                    'date': DateFormat('dd.MM.yyyy')
                                        .format(item.dueDate!)
                                  }),
                            style: TextStyle(color: context.mutedColor)),
                      ],
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: context.cardSurface,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: context.cardShadow,
                        ),
                        child: SelectableText(item.text,
                            style: const TextStyle(fontSize: 14, height: 1.4)),
                      ),
                      if (item.link.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const Key('ord_link'),
                            onPressed: () => openExternal(context, item.link),
                            icon: const Icon(Icons.open_in_new),
                            label: Text('ord_open_link'.tr),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      ..._ackBlock(item),
                      if (item.canReport) ...[
                        const SizedBox(height: 16),
                        OutlinedButton.icon(
                          key: const Key('ord_report'),
                          onPressed: () => Get.to(() => OrderReportScreen(
                              orderId: item.id, title: item.title)),
                          icon: const Icon(Icons.checklist),
                          label: Text(item.total == null
                              ? 'ord_report'.tr
                              : 'ord_progress'.trParams({
                                  'acked': '${item.acked ?? 0}',
                                  'total': '${item.total}'
                                })),
                        ),
                      ],
                      if (item.canRemind) ...[
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const Key('ord_remind'),
                          onPressed: _busy ? null : () => _act('remind'),
                          icon: const Icon(Icons.notifications_active_outlined),
                          label: Text('ord_remind'.tr),
                        ),
                      ],
                      if (item.canWithdraw) ...[
                        const SizedBox(height: 8),
                        TextButton.icon(
                          key: const Key('ord_withdraw'),
                          onPressed: _busy ? null : () => _act('withdraw'),
                          icon: const Icon(Icons.undo),
                          label: Text('ord_withdraw'.tr),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  List<Widget> _ackBlock(OrderDoc item) {
    if (!item.addressed || item.withdrawn) return const [];
    if (item.isAcked) {
      return [
        Row(
          children: [
            Icon(Icons.check_circle,
                color: context.readable(const Color(0xFF2E7D32))),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  'ord_acked_at'.trParams({
                    'date': DateFormat('dd.MM.yyyy HH:mm').format(item.ackedAt!)
                  }),
                  key: const Key('ord_acked')),
            ),
          ],
        ),
      ];
    }
    return [
      Text('ord_ack_hint'.tr,
          style: TextStyle(fontSize: 12, color: context.mutedColor)),
      const SizedBox(height: 8),
      SizedBox(
        height: 48,
        child: ElevatedButton.icon(
          key: const Key('ord_ack'),
          onPressed: _busy ? null : () => _act('ack'),
          icon: const Icon(Icons.done_all),
          label: Text('ord_ack'.tr),
        ),
      ),
    ];
  }
}
