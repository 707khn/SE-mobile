import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart' show AssignPerson;
import '../requests/tech_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';
import '../widgets/person_picker_dialog.dart';

const outageKinds = [
  'power',
  'network',
  'phone',
  'service',
  'water',
  'heat',
  'other'
];
const assetKinds = [
  'pc',
  'laptop',
  'monitor',
  'printer',
  'phone',
  'ups',
  'other'
];

IconData _outageIcon(String kind) => switch (kind) {
      'power' => Icons.power_off_outlined,
      'network' => Icons.wifi_off,
      'phone' => Icons.phone_disabled_outlined,
      'service' => Icons.cloud_off_outlined,
      'water' => Icons.water_drop_outlined,
      'heat' => Icons.thermostat_outlined,
      _ => Icons.warning_amber_outlined,
    };

IconData _assetIcon(String kind) => switch (kind) {
      'pc' => Icons.desktop_windows_outlined,
      'laptop' => Icons.laptop_outlined,
      'monitor' => Icons.monitor_outlined,
      'printer' => Icons.print_outlined,
      'phone' => Icons.phone_outlined,
      'ups' => Icons.battery_charging_full_outlined,
      _ => Icons.devices_other_outlined,
    };

/// «09.03, 09:00–13:00» или «10.03 18:00 — 11.03 08:00».
String outageWhen(Outage o) {
  final day = DateFormat('dd.MM');
  final time = DateFormat('HH:mm');
  if (DateUtils.isSameDay(o.startsAt, o.endsAt)) {
    return 'ta_when_day'.trParams({
      'day': day.format(o.startsAt),
      'from': time.format(o.startsAt),
      'to': time.format(o.endsAt),
    });
  }
  final full = DateFormat('dd.MM HH:mm');
  return 'ta_when_span'
      .trParams({'from': full.format(o.startsAt), 'to': full.format(o.endsAt)});
}

String _errorText(TechResult result) {
  final key = 'ta_err_${result.error}';
  return result.error != null && key.tr != key ? key.tr : 'it_err_failed'.tr;
}

/// Плановые отключения, своя техника, а у ОИТиС — ещё учёт техники.
class TechScreen extends StatefulWidget {
  const TechScreen({Key? key, this.now}) : super(key: key);

  /// Время завода — подменяется в проверках.
  final DateTime? now;

  @override
  State<TechScreen> createState() => _TechScreenState();
}

class _TechScreenState extends State<TechScreen> {
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  OutageList _outages = const OutageList();
  MyAssets _mine = const MyAssets();
  final _query = TextEditingController();
  Timer? _debounce;
  List<ItAsset>? _registry;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final outages = await fetchOutages();
      final mine = await fetchMyAssets();
      final registry = mine.staff ? await searchAssets(_query.text) : null;
      if (!mounted) return;
      setState(() {
        _outages = outages;
        _mine = mine;
        _registry = registry;
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

  void _search(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final found = await searchAssets(_query.text);
        if (mounted) setState(() => _registry = found);
      } catch (_) {}
    });
  }

  void _show(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _run(Future<TechResult> call, {String? done}) async {
    setState(() => _busy = true);
    final result = await call;
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok) {
      _show(_errorText(result));
      return;
    }
    _show(done ?? 'ta_saved'.tr);
    _load();
  }

  Future<void> _announce() async {
    final sent = await Get.to<int>(() => OutageFormScreen(now: widget.now));
    if (sent == null || !mounted) return;
    _show('ta_sent'.trParams({'count': '$sent'}));
    _load();
  }

  Future<void> _cancel(Outage outage) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('ta_cancel'.tr),
        content: Text('ta_cancel_confirm'.tr),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr)),
          TextButton(
              key: const Key('ta_cancel_ok'),
              onPressed: () => Navigator.pop(context, true),
              child: Text('ta_cancel'.tr)),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    await _run(cancelOutage(outage.id), done: 'ta_cancelled'.tr);
  }

  Future<void> _addAsset() async {
    final kind = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('ta_add'.tr),
        children: [
          for (final k in assetKinds)
            SimpleDialogOption(
              key: Key('ta_asset_kind_$k'),
              onPressed: () => Navigator.pop(context, k),
              child: Row(children: [
                Icon(_assetIcon(k)),
                const SizedBox(width: 12),
                Text('ta_asset_kind_$k'.tr),
              ]),
            ),
        ],
      ),
    );
    if (kind == null || !mounted) return;
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'ta_asset_kind_$kind'.tr,
        fields: [
          DialogField('model', 'ta_model'.tr, required: true),
          DialogField('inventory_no', 'ta_inventory'.tr),
          DialogField('serial', 'ta_serial'.tr),
          DialogField('room', 'ta_room_field'.tr),
        ],
        okLabel: 'ta_add'.tr,
      ),
    );
    if (fields == null || !mounted) return;
    await _run(addAsset(kind, fields));
  }

  Future<void> _assetMenu(ItAsset asset) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(asset.model),
            subtitle: Text(_assetLine(asset)),
          ),
          ListTile(
            key: const Key('ta_asset_assign'),
            leading: const Icon(Icons.person_add_alt),
            title: Text('ta_assign'.tr),
            onTap: () => Navigator.pop(context, 'assign'),
          ),
          if (asset.holder != null)
            ListTile(
              key: const Key('ta_asset_release'),
              leading: const Icon(Icons.assignment_return_outlined),
              title: Text('ta_release'.tr),
              onTap: () => Navigator.pop(context, 'release'),
            ),
          ListTile(
            key: const Key('ta_asset_writeoff'),
            leading: const Icon(Icons.delete_outline),
            title: Text('ta_writeoff'.tr),
            onTap: () => Navigator.pop(context, 'writeoff'),
          ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'assign') {
      final person = await showDialog<AssignPerson>(
        context: context,
        builder: (_) => PersonPickerDialog(
            title: 'ta_assign'.tr, search: searchAssetPeople),
      );
      if (person == null || !mounted) return;
      await _run(assetAction(asset.id, 'assign', employeeId: person.id));
    } else {
      await _run(assetAction(asset.id, action));
    }
  }

  @override
  Widget build(BuildContext context) {
    final registry = _registry;
    final tabs = [
      Tab(text: 'ta_tab_outages'.tr),
      Tab(text: 'ta_tab_mine'.tr),
      if (registry != null) Tab(text: 'ta_tab_registry'.tr),
    ];
    return DefaultTabController(
      key: ValueKey(tabs.length),
      length: tabs.length,
      child: Builder(builder: (context) {
        final tab = DefaultTabController.of(context);
        return Scaffold(
          backgroundColor: context.pageColor,
          appBar: AppBar(
            title: BigText(content: 'ta_title'.tr, color: Colors.white),
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'refresh'.tr,
                onPressed: _loading ? null : _load,
              ),
            ],
            bottom: TabBar(
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              indicatorColor: Colors.white,
              tabs: tabs,
            ),
          ),
          floatingActionButton: AnimatedBuilder(
            animation: tab,
            builder: (_, __) {
              if (_loading || _problem != null) return const SizedBox.shrink();
              if (tab.index == 0 && _outages.staff) {
                return FloatingActionButton.extended(
                  key: const Key('ta_announce'),
                  onPressed: _busy ? null : _announce,
                  icon: const Icon(Icons.campaign_outlined),
                  label: Text('ta_announce'.tr),
                );
              }
              if (tab.index == 2 && registry != null) {
                return FloatingActionButton.extended(
                  key: const Key('ta_add'),
                  onPressed: _busy ? null : _addAsset,
                  icon: const Icon(Icons.add),
                  label: Text('ta_add'.tr),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : _problem != null
                  ? LoadErrorView(problem: _problem, onRetry: _load)
                  : TabBarView(children: [
                      _outagesView(),
                      _mineView(),
                      if (registry != null) _registryView(registry),
                    ]),
        );
      }),
    );
  }

  Widget _empty(String text) => ListView(children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center),
        ),
      ]);

  Widget _outagesView() {
    final items = _outages.items;
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? _empty('ta_outages_empty'.tr)
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _outageTile(items[i]),
            ),
    );
  }

  Widget _outageTile(Outage o) {
    final faded = o.state == 'past' || o.state == 'cancelled';
    final color = context.readable(o.state == 'now'
        ? const Color(0xFFC62828)
        : o.mine
            ? const Color(0xFFE65100)
            : const Color(0xFF757575));
    final who =
        o.departments.isEmpty ? 'ta_everyone'.tr : o.departments.join(', ');
    return Opacity(
      opacity: faded ? 0.55 : 1,
      child: ListTile(
        key: Key('ta_outage_${o.id}'),
        leading: Icon(_outageIcon(o.kind), color: color),
        title: Text('${'ta_kind_${o.kind}'.tr} · ${outageWhen(o)}'),
        subtitle: Text([
          if (o.note.isNotEmpty) o.note,
          who,
          if (o.mine && !faded) 'ta_mine_badge'.tr,
        ].join('\n')),
        isThreeLine: true,
        trailing: o.state == 'planned' || o.state == 'now'
            ? (_outages.staff
                ? IconButton(
                    key: Key('ta_outage_cancel_${o.id}'),
                    icon: const Icon(Icons.cancel_outlined),
                    tooltip: 'ta_cancel'.tr,
                    onPressed: _busy ? null : () => _cancel(o),
                  )
                : Text('ta_state_${o.state}'.tr,
                    style: TextStyle(color: color, fontSize: 12)))
            : Text('ta_state_${o.state}'.tr,
                style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  String _assetLine(ItAsset a) => [
        'ta_asset_kind_${a.kind}'.tr,
        if (a.inventoryNo.isNotEmpty)
          'ta_inventory_no'.trParams({'no': a.inventoryNo}),
        if (a.room.isNotEmpty) 'ta_room'.trParams({'room': a.room}),
      ].join(' · ');

  Widget _mineView() {
    final items = _mine.items;
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? _empty('ta_mine_empty'.tr)
          : ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final a = items[i];
                return ListTile(
                  key: Key('ta_mine_${a.id}'),
                  leading: Icon(_assetIcon(a.kind)),
                  title: Text(a.model),
                  subtitle: Text(_assetLine(a)),
                );
              },
            ),
    );
  }

  Widget _registryView(List<ItAsset> items) {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: TextField(
          key: const Key('ta_search'),
          controller: _query,
          onChanged: _search,
          decoration: InputDecoration(
              hintText: 'ta_search'.tr, prefixIcon: const Icon(Icons.search)),
        ),
      ),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          child: items.isEmpty
              ? _empty('ta_registry_empty'.tr)
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final a = items[i];
                    return ListTile(
                      key: Key('ta_asset_${a.id}'),
                      leading: Icon(_assetIcon(a.kind)),
                      title: Text(a.model),
                      subtitle: Text([
                        _assetLine(a),
                        a.holder?.name ?? 'ta_free'.tr,
                      ].join('\n')),
                      isThreeLine: true,
                      onTap: _busy ? null : () => _assetMenu(a),
                    );
                  },
                ),
        ),
      ),
    ]);
  }
}

/// Объявление об отключении: что, когда и каким подразделениям.
///
/// Возвращает, скольким людям ушло оповещение; null — передумали.
class OutageFormScreen extends StatefulWidget {
  const OutageFormScreen({Key? key, this.now}) : super(key: key);

  final DateTime? now;

  @override
  State<OutageFormScreen> createState() => _OutageFormScreenState();
}

class _OutageFormScreenState extends State<OutageFormScreen> {
  final _note = TextEditingController();
  String _kind = 'power';
  late DateTime _from;
  late DateTime _to;
  List<String>? _departments;
  final Set<String> _chosen = {};
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // По умолчанию — завтра с девяти до часу: так чаще всего и бывает.
    final now = widget.now ?? DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    _from = tomorrow.add(const Duration(hours: 9));
    _to = tomorrow.add(const Duration(hours: 13));
    _loadDepartments();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadDepartments() async {
    try {
      final names = await fetchOutageDepartments();
      if (mounted) setState(() => _departments = names);
    } catch (_) {
      if (mounted) setState(() => _departments = const []);
    }
  }

  Future<DateTime?> _pick(DateTime current) async {
    final now = widget.now ?? DateTime.now();
    final day = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 90)),
    );
    if (day == null || !mounted) return null;
    final time = await showTimePicker(
        context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null) return null;
    return DateTime(day.year, day.month, day.day, time.hour, time.minute);
  }

  Future<void> _send() async {
    if (!_to.isAfter(_from)) {
      setState(() => _error = 'ta_err_ends_before'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await announceOutage(
      kind: _kind,
      startsAt: _from,
      endsAt: _to,
      note: _note.text.trim(),
      departments: [
        for (final d in _departments ?? const <String>[])
          if (_chosen.contains(d)) d
      ],
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (!result.ok) {
      setState(() => _error = _errorText(result));
      return;
    }
    Get.back(result: result.notified ?? 0);
  }

  @override
  Widget build(BuildContext context) {
    final stamp = DateFormat('dd.MM.yyyy HH:mm');
    final departments = _departments;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
          title: BigText(content: 'ta_announce'.tr, color: Colors.white)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('ta_what'.tr, style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final k in outageKinds)
              ChoiceChip(
                key: Key('ta_kind_$k'),
                avatar: Icon(_outageIcon(k), size: 18),
                label: Text('ta_kind_$k'.tr),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ]),
          const SizedBox(height: 12),
          ListTile(
            key: const Key('ta_from'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.play_circle_outline),
            title: Text('ta_date_from'.tr),
            subtitle: Text(stamp.format(_from)),
            onTap: () async {
              final picked = await _pick(_from);
              if (picked == null || !mounted) return;
              setState(() {
                final length = _to.difference(_from);
                _from = picked;
                // Сдвинули начало — конец едет вместе с ним.
                _to = picked.add(length.isNegative ? Duration.zero : length);
              });
            },
          ),
          ListTile(
            key: const Key('ta_to'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.stop_circle_outlined),
            title: Text('ta_date_to'.tr),
            subtitle: Text(stamp.format(_to)),
            onTap: () async {
              final picked = await _pick(_to);
              if (picked != null && mounted) setState(() => _to = picked);
            },
          ),
          TextField(
            key: const Key('ta_note'),
            controller: _note,
            maxLines: 2,
            decoration: InputDecoration(labelText: 'ta_note'.tr),
          ),
          const SizedBox(height: 16),
          Text('ta_departments'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (_chosen.isEmpty)
            Text('ta_departments_all'.tr,
                style: const TextStyle(color: Colors.grey)),
          if (departments == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            for (final (i, d) in departments.indexed)
              CheckboxListTile(
                key: Key('ta_dep_$i'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _chosen.contains(d),
                title: Text(d),
                onChanged: (on) => setState(
                    () => on == true ? _chosen.add(d) : _chosen.remove(d)),
              ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child:
                  Text(_error!, style: TextStyle(color: Colors.red.shade700)),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('ta_send'),
            onPressed: _sending ? null : _send,
            icon: const Icon(Icons.campaign_outlined),
            label: Text('ta_send'.tr),
          ),
        ],
      ),
    );
  }
}
