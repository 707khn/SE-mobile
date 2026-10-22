import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/order_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';

/// Кто ознакомлен, а кто нет: неознакомленные сверху, по отделам.
class OrderReportScreen extends StatefulWidget {
  const OrderReportScreen({Key? key, required this.orderId, this.title = ''})
      : super(key: key);

  final int orderId;
  final String title;

  @override
  State<OrderReportScreen> createState() => _OrderReportScreenState();
}

class _OrderReportScreenState extends State<OrderReportScreen> {
  OrderReport? _report;
  bool _loading = true;
  bool _onlyPending = true;
  LoadProblem? _problem;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final report = await fetchOrderReport(widget.orderId);
      if (!mounted) return;
      setState(() {
        _report = report;
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

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'ord_report'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading && report == null
          ? const Center(child: CircularProgressIndicator())
          : report == null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : _body(report),
    );
  }

  Widget _body(OrderReport report) {
    final people = _onlyPending
        ? report.people.where((p) => p.ackedAt == null).toList()
        : report.people;
    final rows = <Widget>[];
    String? department;
    for (final p in people) {
      if (p.department != department) {
        department = p.department;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(department.isEmpty ? '—' : department,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.mutedColor)),
        ));
      }
      rows.add(ListTile(
        dense: true,
        leading: Icon(
            p.ackedAt == null
                ? Icons.radio_button_unchecked
                : Icons.check_circle,
            color: p.ackedAt == null
                ? context.mutedColor
                : context.readable(const Color(0xFF2E7D32))),
        title: Text(p.name),
        subtitle: p.ackedAt == null
            ? null
            : Text(DateFormat('dd.MM.yyyy HH:mm').format(p.ackedAt!)),
      ));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (widget.title.isNotEmpty)
                  Text(widget.title,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text(
                    'ord_progress'.trParams({
                      'acked': '${report.acked}',
                      'total': '${report.total}'
                    }),
                    key: const Key('ord_report_progress')),
                const SizedBox(height: 6),
                if (report.total > 0)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: report.acked / report.total,
                      minHeight: 6,
                      backgroundColor: context.hairlineColor,
                    ),
                  ),
                const SizedBox(height: 8),
                FilterChip(
                  key: const Key('ord_only_pending'),
                  label: Text('ord_only_pending'.tr),
                  selected: _onlyPending,
                  onSelected: (v) => setState(() => _onlyPending = v),
                ),
              ],
            ),
          ),
          ...rows,
        ],
      ),
    );
  }
}
