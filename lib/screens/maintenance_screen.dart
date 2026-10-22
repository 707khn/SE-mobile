import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart' show AssignPerson;
import '../requests/maintenance_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';
import '../widgets/person_picker_dialog.dart';

String _date(DateTime? day) =>
    day == null ? '' : DateFormat('dd.MM.yyyy').format(day);

String _errorText(MaintenanceResult result) {
  final key = 'pm_err_${result.error}';
  return result.error != null && key.tr != key ? key.tr : 'it_err_failed'.tr;
}

Color _stateColor(String state) => switch (state) {
      'overdue' => const Color(0xFFC62828),
      'week' => const Color(0xFFE65100),
      _ => const Color(0xFF757575),
    };

String _planLine(MaintenancePlan plan) => [
      'pm_every'.trParams({'months': '${plan.everyMonths}'}),
      if (plan.hours != null) 'pm_hours'.trParams({'hours': '${plan.hours}'}),
    ].join(' · ');

Widget _section(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Text(text,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
    );

BoxDecoration _cardDecoration(BuildContext context, {Color? border}) =>
    BoxDecoration(
      color: context.cardSurface,
      borderRadius: BorderRadius.circular(10),
      boxShadow: context.cardShadow,
      border:
          border == null ? null : Border.all(color: border.withOpacity(0.6)),
    );

/// Ближайшие плановые остановки: просроченные, на неделе, позже.
class MaintenanceScreen extends StatefulWidget {
  const MaintenanceScreen({Key? key}) : super(key: key);

  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  MaintenanceSchedule _data = const MaintenanceSchedule();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await fetchMaintenanceSchedule();
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

  Future<void> _open(int equipmentId) async {
    await Get.to(() => EquipmentScreen(equipmentId: equipmentId));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<MaintenancePlan>>{};
    for (final plan in _data.items) {
      groups.putIfAbsent(plan.state, () => []).add(plan);
    }
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'pm_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            key: const Key('pm_equipment'),
            icon: const Icon(Icons.precision_manufacturing_outlined),
            tooltip: 'pm_equipment'.tr,
            onPressed: () async {
              await Get.to(() => const EquipmentListScreen());
              if (mounted) _load();
            },
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
                    padding: const EdgeInsets.only(top: 8, bottom: 32),
                    children: [
                      if (_data.items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text('pm_empty'.tr,
                              key: const Key('pm_empty'),
                              textAlign: TextAlign.center,
                              style: TextStyle(color: context.mutedColor)),
                        ),
                      for (final state in const ['overdue', 'week', 'later'])
                        if (groups[state] != null) ...[
                          _section('pm_state_$state'.tr),
                          for (final plan in groups[state]!) _plan(plan),
                        ],
                    ],
                  ),
                ),
    );
  }

  Widget _plan(MaintenancePlan plan) {
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    final equipment = plan.equipment;
    final color = context.readable(_stateColor(plan.state));
    return InkWell(
      key: Key('pm_plan_${plan.id}'),
      onTap: equipment == null ? null : () => _open(equipment.id),
      child: Container(
        margin:
            EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: _cardDecoration(context,
            border: plan.state == 'later' ? null : color),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(equipment?.name ?? '',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Text(_date(plan.nextOn),
                    key: Key('pm_date_${plan.id}'),
                    style:
                        TextStyle(color: color, fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 2),
            Text(
                [
                  'pm_kind_${plan.kind}'.tr,
                  if (plan.hours != null)
                    'pm_hours'.trParams({'hours': '${plan.hours}'}),
                  if ((equipment?.location ?? '').isNotEmpty)
                    equipment!.location,
                ].join(' · '),
                style: muted),
          ],
        ),
      ),
    );
  }
}

/// Всё оборудование, которое мне видно; службе — с кнопкой «добавить».
class EquipmentListScreen extends StatefulWidget {
  const EquipmentListScreen({Key? key}) : super(key: key);

  @override
  State<EquipmentListScreen> createState() => _EquipmentListScreenState();
}

class _EquipmentListScreenState extends State<EquipmentListScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  EquipmentList _data = const EquipmentList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await fetchEquipmentList();
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

  Future<void> _add() async {
    final id = await Get.to<int?>(() => const EquipmentFormScreen());
    if (id == null || !mounted) return;
    await Get.to(() => EquipmentScreen(equipmentId: id));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
          title: BigText(content: 'pm_equipment'.tr, color: Colors.white)),
      floatingActionButton: _data.planner
          ? FloatingActionButton.extended(
              key: const Key('pm_add_equipment'),
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: Text('pm_add_equipment'.tr),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 96),
                  children: [
                    if (_data.items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('pm_equipment_empty'.tr,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: context.mutedColor)),
                      ),
                    for (final item in _data.items)
                      InkWell(
                        key: Key('pm_equipment_${item.id}'),
                        onTap: () async {
                          await Get.to(
                              () => EquipmentScreen(equipmentId: item.id));
                          if (mounted) _load();
                        },
                        child: Container(
                          margin: EdgeInsets.symmetric(
                              horizontal: Dimensions.width20, vertical: 4),
                          padding: const EdgeInsets.all(12),
                          decoration: _cardDecoration(context),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.name,
                                  style: const TextStyle(fontSize: 15)),
                              Text(
                                  [
                                    if (item.inventoryNo.isNotEmpty)
                                      item.inventoryNo,
                                    if (item.location.isNotEmpty) item.location,
                                  ].join(' · '),
                                  style: muted),
                              if (item.plans.isNotEmpty)
                                Text(
                                    'pm_next_on'.trParams({
                                      'date': _date(item.plans.first.nextOn)
                                    }),
                                    style: muted),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}

/// Службе главного инженера: завести оборудование с мастером и ответственным.
class EquipmentFormScreen extends StatefulWidget {
  const EquipmentFormScreen({Key? key}) : super(key: key);

  @override
  State<EquipmentFormScreen> createState() => _EquipmentFormScreenState();
}

class _EquipmentFormScreenState extends State<EquipmentFormScreen> {
  final _name = TextEditingController();
  final _inventory = TextEditingController();
  final _location = TextEditingController();
  AssignPerson? _master;
  AssignPerson? _engineer;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _inventory.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<AssignPerson?> _pick(String title) => showDialog<AssignPerson>(
      context: context,
      builder: (_) =>
          PersonPickerDialog(title: title, search: searchMaintenancePeople));

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('pm_err_name_required'.tr)));
      return;
    }
    setState(() => _saving = true);
    final result = await createEquipment(
      name: _name.text.trim(),
      inventoryNo: _inventory.text.trim(),
      location: _location.text.trim(),
      masterId: _master?.id,
      engineerId: _engineer?.id,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!result.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_errorText(result))));
      return;
    }
    Get.back(result: result.id);
  }

  Widget _field(String key, TextEditingController controller, String label) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          key: Key(key),
          controller: controller,
          decoration: InputDecoration(
              labelText: label, border: const OutlineInputBorder()),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
          title: BigText(content: 'pm_add_equipment'.tr, color: Colors.white)),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          _field('pm_name', _name, 'pm_name'.tr),
          _field('pm_inventory', _inventory, 'pm_inventory'.tr),
          _field('pm_location', _location, 'pm_location'.tr),
          const SizedBox(height: 8),
          for (final role in const ['master', 'engineer'])
            ListTile(
              key: Key('pm_pick_$role'),
              leading: const Icon(Icons.person_outline),
              title: Text((role == 'master' ? _master : _engineer)?.name ??
                  'pm_none'.tr),
              subtitle: Text('pm_$role'.tr),
              onTap: () async {
                final person = await _pick('pm_$role'.tr);
                if (person == null || !mounted) return;
                setState(() =>
                    role == 'master' ? _master = person : _engineer = person);
              },
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                key: const Key('pm_save'),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.check),
                label: Text('pm_save'.tr),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Оборудование: виды работ, следующие даты, история; «выполнено» и перенос.
class EquipmentScreen extends StatefulWidget {
  const EquipmentScreen({Key? key, required this.equipmentId, this.today})
      : super(key: key);

  final int equipmentId;

  /// Для проверок: от какого дня выбирать дату.
  final DateTime? today;

  @override
  State<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends State<EquipmentScreen> {
  bool _loading = true;
  bool _busy = false;
  bool _planner = false;
  LoadProblem? _problem;
  Equipment? _item;

  DateTime get _today {
    final now = widget.today ?? DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final (item, planner) = await fetchEquipment(widget.equipmentId);
      if (!mounted) return;
      setState(() {
        _item = item;
        _planner = planner;
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

  Future<bool> _run(Future<MaintenanceResult> call) async {
    setState(() => _busy = true);
    final result = await call;
    if (!mounted) return false;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.ok ? 'pm_saved'.tr : _errorText(result))));
    if (result.ok) _load();
    return result.ok;
  }

  Future<DateTime?> _pickDate(DateTime? initial) => showDatePicker(
        context: context,
        initialDate:
            initial != null && !initial.isBefore(_today) ? initial : _today,
        firstDate: _today,
        lastDate: _today.add(const Duration(days: 5 * 365)),
      );

  Future<void> _addPlan(Equipment item) async {
    final kind = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('pm_add_plan'.tr),
        children: [
          for (final k in maintenanceKinds)
            SimpleDialogOption(
              key: Key('pm_kind_$k'),
              onPressed: () => Navigator.pop(context, k),
              child: Text('pm_kind_$k'.tr),
            ),
        ],
      ),
    );
    if (kind == null || !mounted) return;
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'pm_kind_$kind'.tr,
        fields: [
          DialogField('every', 'pm_every_field'.tr,
              number: true, required: true, initial: '6'),
          DialogField('hours', 'pm_hours_field'.tr, number: true),
        ],
        okLabel: 'pm_save'.tr,
      ),
    );
    if (values == null || !mounted) return;
    final next = await _pickDate(null);
    if (next == null || !mounted) return;
    await _run(createMaintenancePlan(
        equipmentId: item.id,
        kind: kind,
        everyMonths: values['every'] ?? '',
        nextOn: next,
        hours: values['hours'] ?? ''));
  }

  Future<void> _done(MaintenancePlan plan) async {
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'pm_kind_${plan.kind}'.tr,
        fields: [DialogField('note', 'pm_done_note'.tr)],
        okLabel: 'pm_done'.tr,
      ),
    );
    if (values == null || !mounted) return;
    await _run(markMaintenanceDone(plan.id, note: values['note'] ?? ''));
  }

  Future<void> _postpone(MaintenancePlan plan) async {
    final next = await _pickDate(plan.nextOn);
    if (next == null || !mounted) return;
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: '${_date(plan.nextOn)} → ${_date(next)}',
        fields: [DialogField('note', 'pm_postpone_note'.tr, required: true)],
        okLabel: 'pm_postpone'.tr,
      ),
    );
    if (values == null || !mounted) return;
    await _run(postponeMaintenance(plan.id, next, values['note'] ?? ''));
  }

  Future<void> _retire(Equipment item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text('pm_retire_confirm'.tr),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr)),
          TextButton(
              key: const Key('pm_confirm'),
              onPressed: () => Navigator.pop(context, true),
              child: Text('pm_yes'.tr)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (await _run(retireEquipment(item.id)) && mounted) Get.back();
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: item?.name ?? 'pm_equipment'.tr, color: Colors.white),
        actions: [
          if (_planner && item != null)
            IconButton(
              key: const Key('pm_retire'),
              icon: const Icon(Icons.delete_outline),
              tooltip: 'pm_retire'.tr,
              onPressed: _busy ? null : () => _retire(item),
            ),
        ],
      ),
      floatingActionButton: _planner && item != null
          ? FloatingActionButton.extended(
              key: const Key('pm_add_plan'),
              onPressed: _busy ? null : () => _addPlan(item),
              icon: const Icon(Icons.add),
              label: Text('pm_add_plan'.tr),
            )
          : null,
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null || item == null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : _body(item),
    );
  }

  Widget _body(Equipment item) {
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 96),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
          child: Text(
              [
                if (item.inventoryNo.isNotEmpty) item.inventoryNo,
                if (item.location.isNotEmpty) item.location,
              ].join(' · '),
              style: TextStyle(color: context.mutedColor)),
        ),
        for (final (label, person) in [
          ('pm_master'.tr, item.master),
          ('pm_engineer'.tr, item.engineer),
        ])
          ListTile(
            dense: true,
            leading: const Icon(Icons.person_outline),
            title: Text(person?.name ?? 'pm_none'.tr),
            subtitle: Text(label),
          ),
        for (final plan in item.plans)
          Container(
            key: Key('pm_card_${plan.id}'),
            margin: EdgeInsets.symmetric(
                horizontal: Dimensions.width20, vertical: 6),
            padding: const EdgeInsets.all(12),
            decoration: _cardDecoration(context,
                border: plan.state == 'later'
                    ? null
                    : context.readable(_stateColor(plan.state))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('pm_kind_${plan.kind}'.tr,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                Text(_planLine(plan), style: muted),
                Text('pm_next_on'.trParams({'date': _date(plan.nextOn)}),
                    key: Key('pm_next_${plan.id}'),
                    style: TextStyle(
                        color: context.readable(_stateColor(plan.state)),
                        fontWeight: FontWeight.w600)),
                if (plan.history.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('pm_history'.tr, style: muted),
                  for (final r in plan.history)
                    Text(
                        [
                          r.action == 'done'
                              ? 'pm_history_done'
                                  .trParams({'date': _date(r.doneOn)})
                              : 'pm_history_postponed'.trParams({
                                  'from': _date(r.plannedOn),
                                  'to': _date(r.newOn)
                                }),
                          if (r.actor != null) r.actor!.name,
                          if (r.note.isNotEmpty) r.note,
                        ].join(' · '),
                        style: muted),
                ],
                if (plan.canMark || _planner)
                  Wrap(
                    spacing: 8,
                    children: [
                      if (plan.canMark)
                        TextButton.icon(
                          key: Key('pm_done_${plan.id}'),
                          onPressed: _busy ? null : () => _done(plan),
                          icon: const Icon(Icons.check),
                          label: Text('pm_done'.tr),
                        ),
                      if (_planner)
                        TextButton.icon(
                          key: Key('pm_postpone_${plan.id}'),
                          onPressed: _busy ? null : () => _postpone(plan),
                          icon: const Icon(Icons.event_repeat),
                          label: Text('pm_postpone'.tr),
                        ),
                      if (_planner)
                        TextButton(
                          key: Key('pm_remove_${plan.id}'),
                          onPressed: _busy
                              ? null
                              : () => _run(removeMaintenancePlan(plan.id)),
                          child: Text('pm_remove'.tr),
                        ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
