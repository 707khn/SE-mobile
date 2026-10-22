import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/hr_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'hr_request_form_screen.dart';

/// «Мои заявки» в отдел кадров.
///
/// Раньше за справкой шли в кадры, а потом звонили узнать, готова ли. Здесь
/// видно, что с заявкой: отправлена, принята, готова — и где забрать.
class HrRequestsScreen extends StatefulWidget {
  const HrRequestsScreen({Key? key}) : super(key: key);

  @override
  State<HrRequestsScreen> createState() => _HrRequestsScreenState();
}

class _HrRequestsScreenState extends State<HrRequestsScreen> {
  bool _loading = true;
  List<HrRequest> _items = [];
  LoadProblem? _problem;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await getMyHrRequests();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _problem = result.problem;
      if (!result.failed) _items = result.items;
    });
  }

  Future<void> _new() async {
    final created = await Get.to<HrRequest>(() => const HrRequestFormScreen());
    if (created == null || !mounted) return;
    setState(() => _items = [created, ..._items]);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('hr_sent'.tr)));
  }

  Future<void> _cancel(HrRequest item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('hr_cancel_title'.tr),
        content: Text(hrKindKey(item.kind).tr),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('hr_cancel_confirm'.tr)),
        ],
      ),
    );
    if (confirmed != true) return;
    final result = await cancelHrRequest(item.id);
    if (!mounted) return;
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.error == 'already_taken'
              ? 'hr_already_taken'.tr
              : 'hr_save_failed'.tr)));
      _load();
      return;
    }
    HapticFeedback.lightImpact();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final failed = _problem != null && _items.isEmpty;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'hr_requests'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _new,
        icon: const Icon(Icons.add),
        label: Text('hr_new'.tr),
      ),
      body: _loading && _items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : failed
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _items.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: [_empty()],
                        )
                      : ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.only(top: 8, bottom: 88),
                          itemCount: _items.length,
                          itemBuilder: (_, i) => HrRequestCard(
                            item: _items[i],
                            onCancel: _items[i].canCancel
                                ? () => _cancel(_items[i])
                                : null,
                          ),
                        ),
                ),
    );
  }

  Widget _empty() {
    return Padding(
      padding: EdgeInsets.all(Dimensions.height30),
      child: Column(
        children: [
          SizedBox(height: Dimensions.height30),
          Icon(Icons.assignment_outlined, size: 56, color: context.mutedColor),
          const SizedBox(height: 12),
          Text('hr_empty'.tr,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('hr_empty_hint'.tr,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: context.mutedColor)),
        ],
      ),
    );
  }
}

/// Цвет состояния: готовая — зелёная, отказ — красный, закрытые — серые.
Color hrStatusColor(BuildContext context, String status) => switch (status) {
      'ready' => Colors.green.shade700,
      'rejected' => Colors.red.shade700,
      'accepted' => context.accentColor,
      'done' || 'cancelled' => context.mutedColor,
      _ => Colors.orange.shade800,
    };

IconData hrKindIcon(String kind) => switch (kind) {
      'vacation' => Icons.beach_access_outlined,
      'income' => Icons.request_quote_outlined,
      _ => Icons.badge_outlined,
    };

/// Карточка заявки — общая для сотрудника и для очереди кадров.
class HrRequestCard extends StatelessWidget {
  const HrRequestCard({
    Key? key,
    required this.item,
    this.onCancel,
    this.showEmployee = false,
    this.actions,
  }) : super(key: key);

  final HrRequest item;
  final VoidCallback? onCancel;
  final bool showEmployee;

  /// Кнопки кадров под карточкой.
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final color = hrStatusColor(context, item.status);
    final date = DateFormat('dd.MM.yyyy');
    final lines = <String>[
      if (item.kind == 'vacation' && item.startDate != null && item.endDate != null)
        '${item.leaveType.isEmpty ? '' : '${item.leaveType}: '}'
            '${date.format(item.startDate!)} — ${date.format(item.endDate!)}'
            ' (${item.vacationDays} ${'days_short'.tr})',
      if (item.kind != 'vacation' && item.copies > 1)
        '${'hr_copies'.tr}: ${item.copies}',
      if (item.details.isNotEmpty) item.details,
    ];
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 5),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: context.cardShadow,
        border: Border(left: BorderSide(color: color, width: 3)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(hrKindIcon(item.kind), size: 20, color: context.mutedColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(hrKindKey(item.kind).tr,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(hrStatusKey(item.status).tr,
                      style: TextStyle(
                          fontSize: 12,
                          color: color,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            if (showEmployee && item.employeeName.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(item.employeeName,
                  style: const TextStyle(fontSize: 14)),
              Text(
                [item.employeeJob, item.employeeDepartment]
                    .where((s) => s.isNotEmpty)
                    .join(' · '),
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
            ],
            for (final line in lines) ...[
              const SizedBox(height: 4),
              Text(line, style: TextStyle(fontSize: 13, color: context.inkColor)),
            ],
            if (item.hrNote.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(item.hrNote,
                    style: TextStyle(fontSize: 13, color: color)),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '№${item.id}'
                    '${item.createdAt == null ? '' : ' · ${DateFormat('dd.MM.yyyy HH:mm').format(item.createdAt!.toLocal())}'}',
                    style: TextStyle(fontSize: 11, color: context.mutedColor),
                  ),
                ),
                if (onCancel != null)
                  TextButton(
                    onPressed: onCancel,
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact),
                    child: Text('hr_cancel'.tr),
                  ),
              ],
            ),
            if (actions != null) actions!,
          ],
        ),
      ),
    );
  }
}
