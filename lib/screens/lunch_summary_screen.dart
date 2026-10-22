import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/lunch_order_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';

/// Столовой: сколько чего готовить и кому что отдать.
class LunchSummaryScreen extends StatefulWidget {
  const LunchSummaryScreen({Key? key, required this.day}) : super(key: key);

  final DateTime day;

  @override
  State<LunchSummaryScreen> createState() => _LunchSummaryScreenState();
}

class _LunchSummaryScreenState extends State<LunchSummaryScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  LunchSummary _data = const LunchSummary();
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await fetchLunchSummary(widget.day);
      if (!mounted) return;
      setState(() {
        _data = data;
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

  Future<void> _toggle(LunchOrder order) async {
    setState(() => _busy.add(order.id));
    final result = await markLunchServed(order.id, !order.served);
    if (!mounted) return;
    setState(() => _busy.remove(order.id));
    if (result.ok) {
      _load();
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('it_err_failed'.tr)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content:
                '${'lo_summary'.tr} · ${DateFormat('dd.MM').format(widget.day)}',
            color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.only(top: 8, bottom: 32),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                        child: Text(
                            'lo_summary_counts'.trParams({
                              'count': '${_data.count}',
                              'served': '${_data.served}',
                            }),
                            key: const Key('lo_counts'),
                            style: muted),
                      ),
                      if (_data.orders.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text('lo_empty_orders'.tr,
                              textAlign: TextAlign.center, style: muted),
                        )
                      else ...[
                        _heading('lo_dishes'.tr),
                        for (final d in _data.dishes)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 3),
                            child: Row(
                              children: [
                                Expanded(child: Text(d.name)),
                                Text('× ${d.quantity}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                        _heading('lo_orders'.tr),
                        for (final o in _data.orders) _order(o),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
        child: Text(text,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      );

  Widget _order(LunchOrder o) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: CheckboxListTile(
          key: Key('lo_served_${o.id}'),
          value: o.served,
          onChanged: _busy.contains(o.id) ? null : (_) => _toggle(o),
          title: Text(o.employeeName,
              style: TextStyle(
                  decoration: o.served ? TextDecoration.lineThrough : null)),
          subtitle: Text([
            o.lines
                .map(
                    (l) => l.quantity > 1 ? '${l.name} ×${l.quantity}' : l.name)
                .join(', '),
            if (o.note.isNotEmpty) o.note,
          ].join('\n')),
        ),
      ),
    );
  }
}
