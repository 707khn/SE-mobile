import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/waybill_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';
import 'waybills_screen.dart';

/// Путевой лист: машина, пробег, топливо и поездки за день.
class WaybillDetailScreen extends StatefulWidget {
  const WaybillDetailScreen({Key? key, required this.waybillId})
      : super(key: key);

  final int waybillId;

  @override
  State<WaybillDetailScreen> createState() => _WaybillDetailScreenState();
}

class _WaybillDetailScreenState extends State<WaybillDetailScreen> {
  Waybill? _item;
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
      final item = await fetchWaybill(widget.waybillId);
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

  Future<void> _send(String action,
      [Map<String, Object?> fields = const {}]) async {
    setState(() => _busy = true);
    final result = await waybillAction(widget.waybillId, action, fields);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    if (result.ok) return;
    final key = 'wb_err_${result.error}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.error != null && key.tr != key
            ? key.tr
            : 'it_err_failed'.tr)));
  }

  Future<void> _addTrip() async {
    final last = _item?.trips.isEmpty ?? true ? null : _item!.trips.last;
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'wb_trip_add'.tr,
        okLabel: 'wb_trip_save'.tr,
        fields: [
          // Откуда — обычно туда, где закончилась прошлая поездка.
          DialogField('origin', 'wb_origin'.tr,
              required: true, initial: last?.destination ?? ''),
          DialogField('destination', 'wb_destination'.tr, required: true),
          DialogField('purpose', 'wb_purpose'.tr),
          DialogField('customer', 'wb_customer'.tr),
          DialogField('departed', 'wb_departed'.tr),
          DialogField('arrived', 'wb_arrived'.tr),
        ],
      ),
    );
    if (fields == null || !mounted) return;
    await _send('trip', fields);
  }

  Future<void> _return() async {
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'wb_return'.tr,
        okLabel: 'wb_return_save'.tr,
        fields: [
          DialogField('odometer_in', 'wb_odometer_in'.tr,
              number: true, required: true),
          DialogField('fuel_added', 'wb_fuel_added'.tr, number: true),
          DialogField('fuel_in', 'wb_fuel_in'.tr, number: true, required: true),
        ],
      ),
    );
    if (fields == null || !mounted) return;
    await _send('return', fields);
  }

  Future<void> _reopen() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
          title: 'wb_reopen'.tr, hint: 'wb_reopen_hint'.tr, required: true),
    );
    if (text == null || !mounted) return;
    await _send('reopen', {'text': text});
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: 'wb_number'.trParams({'id': '${widget.waybillId}'}),
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
                      _header(item),
                      if (item.note.isNotEmpty && item.status == 'open') ...[
                        const SizedBox(height: 12),
                        Container(
                          key: const Key('wb_note'),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: context
                                .readable(const Color(0xFFE65100))
                                .withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('${'wb_note'.tr}: ${item.note}'),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text('wb_trips'.tr,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      if (item.trips.isEmpty)
                        Text('wb_no_trips'.tr,
                            style: TextStyle(color: context.mutedColor)),
                      for (final t in item.trips) _trip(item, t),
                      const SizedBox(height: 16),
                      ..._buttons(item),
                    ],
                  ),
                ),
    );
  }

  Widget _header(Waybill item) {
    final run = item.distance == null
        ? '${item.odometerOut} км'
        : '${item.odometerOut} → ${item.odometerIn} км · ${item.distance} км';
    final fuel = 'wb_fuel_line'.trParams({
      'out': litres(item.fuelOut),
      'added': litres(item.fuelAdded),
      'in': litres(item.fuelIn),
    });
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: context.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(item.plate,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              WaybillChip(status: item.status),
            ],
          ),
          const SizedBox(height: 4),
          Text(
              [
                if (item.date != null)
                  DateFormat('dd.MM.yyyy').format(item.date!),
                if (item.driver != null) item.driver!.name,
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          const SizedBox(height: 8),
          Text('${'wb_run'.tr}: $run', key: const Key('wb_run')),
          const SizedBox(height: 2),
          Text('${'wb_fuel'.tr}: $fuel'),
          if (item.fuelUsed != null)
            Text('wb_used'.trParams({'fuel': litres(item.fuelUsed)}),
                key: const Key('wb_used'),
                style: const TextStyle(fontWeight: FontWeight.w600)),
          if (item.reviewer != null && item.status == 'closed')
            Text('${'wb_reviewer'.tr}: ${item.reviewer!.short}',
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
        ],
      ),
    );
  }

  Widget _trip(Waybill item, WaybillTrip t) {
    final details = [
      if (t.when.isNotEmpty) t.when,
      if (t.purpose.isNotEmpty) t.purpose,
      if (t.customer.isNotEmpty) t.customer,
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${t.origin} → ${t.destination}',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (details.isNotEmpty)
                  Text(details,
                      style:
                          TextStyle(fontSize: 12, color: context.mutedColor)),
              ],
            ),
          ),
          if (item.canEdit)
            IconButton(
              key: Key('wb_trip_remove_${t.id}'),
              tooltip: 'wb_trip_remove'.tr,
              icon: const Icon(Icons.delete_outline),
              onPressed:
                  _busy ? null : () => _send('trip_remove', {'trip_id': t.id}),
            ),
        ],
      ),
    );
  }

  List<Widget> _buttons(Waybill item) {
    Widget button(String key, IconData icon, VoidCallback onPressed,
        {bool primary = false}) {
      final action = _busy ? null : onPressed;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: primary
            ? SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                    key: Key('wb_$key'),
                    onPressed: action,
                    icon: Icon(icon),
                    label: Text('wb_$key'.tr)))
            : OutlinedButton.icon(
                key: Key('wb_$key'),
                onPressed: action,
                icon: Icon(icon),
                label: Text('wb_$key'.tr)),
      );
    }

    return [
      if (item.canEdit) ...[
        button('trip_add', Icons.add_location_alt_outlined, _addTrip),
        button('return', Icons.local_parking, _return, primary: true),
      ],
      if (item.canReview) ...[
        button('close', Icons.check, () => _send('close'), primary: true),
        button('reopen', Icons.undo, _reopen),
      ],
    ];
  }
}
