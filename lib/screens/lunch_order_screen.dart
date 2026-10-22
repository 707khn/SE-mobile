import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/business_trip_request.dart' show tenge;
import '../requests/lunch_order_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'lunch_summary_screen.dart';

/// Предзаказ обеда на день: блюда из меню с количеством.
class LunchOrderScreen extends StatefulWidget {
  const LunchOrderScreen({Key? key, required this.day}) : super(key: key);

  final DateTime day;

  @override
  State<LunchOrderScreen> createState() => _LunchOrderScreenState();
}

class _LunchOrderScreenState extends State<LunchOrderScreen> {
  final _note = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  LoadProblem? _problem;
  LunchDay _data = const LunchDay();
  final Map<int, int> _counts = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await fetchLunchDay(widget.day);
      if (!mounted) return;
      setState(() {
        _data = data;
        _counts
          ..clear()
          ..addAll(_fromOrder(data));
        _note.text = data.order?.note ?? '';
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

  /// Заказ хранит снимок блюд — сопоставляем с меню по категории и имени.
  Map<int, int> _fromOrder(LunchDay data) {
    final order = data.order;
    if (order == null) return {};
    final counts = <int, int>{};
    for (final line in order.lines) {
      for (final dish in data.menu) {
        if (dish.name == line.name && dish.category == line.category) {
          counts[dish.id] = line.quantity;
          break;
        }
      }
    }
    return counts;
  }

  double get _total => _data.menu
      .fold(0, (sum, d) => sum + (d.price ?? 0) * (_counts[d.id] ?? 0));

  void _show(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  String _errorText(String? code) {
    final key = 'lo_err_$code';
    return code != null && key.tr != key ? key.tr : 'it_err_failed'.tr;
  }

  Future<void> _save() async {
    final items = {
      for (final e in _counts.entries)
        if (e.value > 0) e.key: e.value
    };
    if (items.isEmpty) {
      _show('lo_err_empty'.tr);
      return;
    }
    setState(() => _saving = true);
    final result =
        await saveLunchOrder(widget.day, items, note: _note.text.trim());
    if (!mounted) return;
    setState(() => _saving = false);
    if (!result.ok) {
      _show(_errorText(result.error));
      return;
    }
    _show('lo_saved'.tr);
    _load();
  }

  Future<void> _cancel() async {
    setState(() => _saving = true);
    final result = await cancelLunchOrder(widget.day);
    if (!mounted) return;
    setState(() => _saving = false);
    if (!result.ok) {
      _show(_errorText(result.error));
      return;
    }
    _show('lo_cancelled'.tr);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final order = _data.order;
    final served = order?.served == true;
    final editable = _data.open && !served;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: 'lo_title'
                .trParams({'date': DateFormat('dd.MM').format(widget.day)}),
            color: Colors.white),
        actions: [
          if (_data.canteen)
            IconButton(
              key: const Key('lo_summary'),
              icon: const Icon(Icons.list_alt),
              tooltip: 'lo_summary'.tr,
              onPressed: () =>
                  Get.to(() => LunchSummaryScreen(day: widget.day)),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 32),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                      child: Text(
                          served
                              ? 'lo_served'.tr
                              : _data.menu.isEmpty
                                  ? 'lo_no_menu'.tr
                                  : _data.open
                                      ? 'lo_open_until'
                                          .trParams({'time': _data.cutoff})
                                      : 'lo_closed'.tr,
                          key: const Key('lo_state'),
                          style: TextStyle(color: context.mutedColor)),
                    ),
                    for (final dish in _data.menu) _dish(dish, editable),
                    if (_data.menu.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        child: TextField(
                          key: const Key('lo_note'),
                          controller: _note,
                          enabled: editable,
                          maxLength: 200,
                          decoration: InputDecoration(
                            labelText: 'lo_note'.tr,
                            border: const OutlineInputBorder(),
                            counterText: '',
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        child: Text(
                            'lo_total'.trParams({'sum': tenge(_total.round())}),
                            key: const Key('lo_total'),
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 2, 20, 12),
                        child: Text('lo_pay_note'.tr,
                            style: TextStyle(
                                fontSize: 12, color: context.mutedColor)),
                      ),
                      if (editable)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: SizedBox(
                            height: 48,
                            child: ElevatedButton.icon(
                              key: const Key('lo_save'),
                              onPressed: _saving ? null : _save,
                              icon: const Icon(Icons.check),
                              label: Text(order == null
                                  ? 'lo_save'.tr
                                  : 'lo_update'.tr),
                            ),
                          ),
                        ),
                      if (editable && order != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                          child: OutlinedButton.icon(
                            key: const Key('lo_cancel'),
                            onPressed: _saving ? null : _cancel,
                            icon: const Icon(Icons.close),
                            label: Text('lo_cancel'.tr),
                          ),
                        ),
                    ],
                  ],
                ),
    );
  }

  Widget _dish(LunchDish dish, bool editable) {
    final count = _counts[dish.id] ?? 0;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: count > 0
            ? Border.all(color: context.accentColor.withOpacity(0.6))
            : null,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dish.name, style: const TextStyle(fontSize: 15)),
                Text(
                    [
                      dish.category,
                      if (dish.price != null) tenge(dish.price!.round()),
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: context.mutedColor)),
              ],
            ),
          ),
          if (editable)
            IconButton(
              key: Key('lo_minus_${dish.id}'),
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: count == 0
                  ? null
                  : () => setState(() => _counts[dish.id] = count - 1),
            ),
          SizedBox(
            width: 24,
            child: Text('$count',
                key: Key('lo_count_${dish.id}'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (editable)
            IconButton(
              key: Key('lo_plus_${dish.id}'),
              icon: const Icon(Icons.add_circle_outline),
              onPressed: count >= 5
                  ? null
                  : () => setState(() => _counts[dish.id] = count + 1),
            ),
        ],
      ),
    );
  }
}
