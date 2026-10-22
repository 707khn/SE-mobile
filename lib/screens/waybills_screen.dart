import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/waybill_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';
import 'waybill_detail_screen.dart';

Color waybillColor(String status) => switch (status) {
      'open' => const Color(0xFFE65100),
      'returned' => const Color(0xFF1565C0),
      'closed' => const Color(0xFF2E7D32),
      _ => const Color(0xFF757575),
    };

class WaybillChip extends StatelessWidget {
  const WaybillChip({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(waybillColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('wb_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Путевые листы: водителю — готовность на сегодня и свои листы; механику
/// и руководству — все листы за день с пробегом и расходом.
class WaybillsScreen extends StatefulWidget {
  const WaybillsScreen({Key? key}) : super(key: key);

  @override
  State<WaybillsScreen> createState() => _WaybillsScreenState();
}

class _WaybillsScreenState extends State<WaybillsScreen> {
  bool _loading = true;
  bool _opening = false;
  LoadProblem? _problem;
  WaybillOverview _data = const WaybillOverview();
  DateTime? _day;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await fetchWaybills(day: _day);
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

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _day ?? _data.date ?? today,
      firstDate: today.subtract(const Duration(days: 366)),
      lastDate: today,
    );
    if (picked == null || !mounted) return;
    _day = picked;
    _load();
  }

  Future<void> _openDetail(int id) async {
    await Get.to(() => WaybillDetailScreen(waybillId: id));
    if (mounted) _load();
  }

  Future<void> _create() async {
    final ready = _data.ready;
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'wb_open'.tr,
        okLabel: 'wb_open'.tr,
        fields: [
          DialogField('odometer_out', 'wb_odometer_out'.tr,
              number: true,
              required: true,
              initial: ready.odometer?.toString() ?? ''),
          DialogField('fuel_out', 'wb_fuel_out'.tr,
              number: true,
              required: true,
              initial: ready.fuel == null ? '' : litres(ready.fuel)),
        ],
      ),
    );
    if (fields == null || !mounted) return;
    setState(() => _opening = true);
    final result = await openWaybill(
        fuelOut: fields['fuel_out']!, odometerOut: fields['odometer_out']!);
    if (!mounted) return;
    setState(() => _opening = false);
    if (result.ok) {
      _openDetail(result.item!.id);
      return;
    }
    final key = 'wb_err_${result.error}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.error != null && key.tr != key
            ? key.tr
            : 'it_err_failed'.tr)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'wb_title'.tr, color: Colors.white),
        actions: [
          if (_data.staff)
            IconButton(
              key: const Key('wb_date'),
              icon: const Icon(Icons.calendar_month_outlined),
              onPressed: _loading ? null : _pickDay,
            ),
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
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(top: 8, bottom: 32),
                    children: [
                      if (_data.driver) ..._driver(),
                      if (_data.staff) ..._staff(),
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

  List<Widget> _driver() {
    final ready = _data.ready;
    String state(bool marked, bool yes) => !marked
        ? 'wb_ready_wait'.tr
        : yes
            ? 'wb_ready_yes'.tr
            : 'wb_ready_no'.tr;
    Widget line(String label, bool marked, bool yes) => Row(
          children: [
            Icon(
                !marked
                    ? Icons.schedule
                    : yes
                        ? Icons.check_circle
                        : Icons.cancel,
                size: 18,
                color: !marked
                    ? context.mutedColor
                    : context.readable(yes
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFFC62828))),
            const SizedBox(width: 6),
            Text('$label: ${state(marked, yes)}'),
          ],
        );
    return [
      Container(
        margin:
            EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.cardSurface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: context.cardShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                ready.plate.isEmpty
                    ? 'wb_today'.tr
                    : '${'wb_today'.tr} · ${ready.plate}',
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            line('wb_ready_med'.tr, ready.examined, ready.admitted),
            const SizedBox(height: 4),
            line('wb_ready_car'.tr, ready.checked, ready.released),
            const SizedBox(height: 12),
            if (ready.openId != null)
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  key: const Key('wb_open_current'),
                  onPressed: () => _openDetail(ready.openId!),
                  icon: const Icon(Icons.route_outlined),
                  label: Text('wb_open_current'.tr),
                ),
              )
            else if (ready.canOpen)
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  key: const Key('wb_open'),
                  onPressed: _opening ? null : _create,
                  icon: const Icon(Icons.add_road),
                  label: Text('wb_open'.tr),
                ),
              )
            else
              Text('wb_cannot_open'.tr,
                  key: const Key('wb_cannot_open'),
                  style: TextStyle(fontSize: 12, color: context.mutedColor)),
          ],
        ),
      ),
      _heading('wb_mine'.tr),
      if (_data.mine.isEmpty) _empty('wb_empty_mine'.tr),
      for (final w in _data.mine) _row(w, showDriver: false),
    ];
  }

  List<Widget> _staff() {
    final day = _data.date;
    final totals = _data.totals;
    return [
      _heading(day == null ? '' : DateFormat('dd.MM.yyyy').format(day)),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
        child: Text(
            'wb_day_totals'.trParams({
              'count': '${totals.count}',
              'open': '${totals.open}',
              'returned': '${totals.returned}',
              'km': '${totals.distance}',
              'fuel': litres(totals.fuelUsed),
            }),
            key: const Key('wb_totals'),
            style: TextStyle(fontSize: 12, color: context.mutedColor)),
      ),
      if (_data.items.isEmpty) _empty('wb_empty_day'.tr),
      for (final w in _data.items) _row(w, showDriver: true),
    ];
  }

  Widget _empty(String text) => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.mutedColor)),
      );

  Widget _row(Waybill w, {required bool showDriver}) {
    final details = [
      if (!showDriver && w.date != null) DateFormat('dd.MM').format(w.date!),
      if (w.distance != null) '${w.distance} км',
      if (w.fuelUsed != null) 'wb_used'.trParams({'fuel': litres(w.fuelUsed)}),
    ].join(' · ');
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: w.canReview
            ? Border(left: BorderSide(color: waybillColor(w.status), width: 3))
            : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _openDetail(w.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                        showDriver
                            ? '${w.driver?.short ?? ''} · ${w.plate}'
                            : '№${w.id} · ${w.plate}',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  WaybillChip(status: w.status),
                ],
              ),
              if (details.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(details,
                      style:
                          TextStyle(fontSize: 12, color: context.mutedColor)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
