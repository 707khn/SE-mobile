import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart' show AssignPerson;
import '../requests/reception_request.dart';
import '../utils/app_theme.dart';
import '../utils/lang.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/day_navigator.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';

String _time(DateTime at) => DateFormat('HH:mm').format(at);

String _dayTime(DateTime at) {
  final day = DateFormat('EEEE, d MMMM', Lang.dates).format(at);
  return '${day[0].toUpperCase()}${day.substring(1)}, ${_time(at)}';
}

String _errorText(ReceptionResult result, {String? tooMany}) {
  if (result.error == 'too_many' && tooMany != null) return tooMany.tr;
  final key = 'rc_err_${result.error}';
  return result.error != null && key.tr != key ? key.tr : 'it_err_failed'.tr;
}

Color _statusColor(String? status) =>
    status == 'confirmed' ? const Color(0xFF2E7D32) : const Color(0xFFE65100);

/// Запись на приём: свободные окна руководителей; у приёмной — её день.
class ReceptionScreen extends StatefulWidget {
  const ReceptionScreen({Key? key, this.today}) : super(key: key);

  /// День завода — подменяется в проверках.
  final DateTime? today;

  @override
  State<ReceptionScreen> createState() => _ReceptionScreenState();
}

class _ReceptionScreenState extends State<ReceptionScreen> {
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  ReceptionCard _card = const ReceptionCard();
  String? _host;
  late DateTime _day;
  String? _deskHost;
  List<ReceptionSlot>? _desk;

  @override
  void initState() {
    super.initState();
    final today = widget.today ?? DateTime.now();
    _day = DateTime(today.year, today.month, today.day);
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final card = await fetchReception();
      final desk = card.manager || card.host
          ? await fetchReceptionDesk(_day, hostId: _deskHost)
          : null;
      if (!mounted) return;
      setState(() {
        _card = card;
        _desk = desk;
        _host ??= card.hosts.isEmpty ? null : card.hosts.first.id;
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

  Future<void> _loadDesk() async {
    try {
      final desk = await fetchReceptionDesk(_day, hostId: _deskHost);
      if (mounted) setState(() => _desk = desk);
    } catch (_) {}
  }

  void _show(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _run(Future<ReceptionResult> call,
      {String? done, String? tooMany}) async {
    setState(() => _busy = true);
    final result = await call;
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok) {
      _show(_errorText(result, tooMany: tooMany));
      _load();
      return;
    }
    _show(done ?? 'rc_saved'.tr);
    _load();
  }

  Future<void> _book(ReceptionSlot slot) async {
    final topic = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
        title: 'rc_book_title'.trParams({
          'name': slot.host?.name ?? '',
          'time': _dayTime(slot.startsAt),
        }),
        hint: 'rc_topic'.tr,
        required: true,
      ),
    );
    if (topic == null || !mounted) return;
    await _run(bookReception(slot.id, topic), done: 'rc_booked'.tr);
  }

  Future<void> _open() async {
    final host = _deskHost ?? _host;
    if (host == null) return;
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: '${'rc_open'.tr}: ${DateFormat('dd.MM.yyyy').format(_day)}',
        fields: [
          DialogField('from', 'rc_from'.tr, required: true, initial: '14:00'),
          DialogField('to', 'rc_to'.tr, required: true, initial: '16:00'),
          DialogField('step', 'rc_step'.tr,
              number: true, required: true, initial: '15'),
        ],
        okLabel: 'rc_open'.tr,
      ),
    );
    if (fields == null || !mounted) return;
    setState(() => _busy = true);
    final result = await openReceptionSlots(host, _day, fields['from'] ?? '',
        fields['to'] ?? '', fields['step'] ?? '');
    if (!mounted) return;
    setState(() => _busy = false);
    _show(result.ok
        ? 'rc_opened'.trParams({'count': '${result.added ?? 0}'})
        : _errorText(result, tooMany: 'rc_err_too_many_slots'));
    if (result.ok) _load();
  }

  Future<void> _deskSlot(ReceptionSlot slot) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(slot.employee?.name ?? 'rc_free_slot'.tr),
            subtitle: Text(slot.topic),
          ),
          if (slot.booked && slot.status != 'confirmed')
            ListTile(
              key: const Key('rc_confirm'),
              leading: const Icon(Icons.check_circle_outline),
              title: Text('rc_confirm'.tr),
              onTap: () => Navigator.pop(context, 'confirm'),
            ),
          if (slot.booked)
            ListTile(
              key: const Key('rc_decline'),
              leading: const Icon(Icons.cancel_outlined),
              title: Text('rc_decline'.tr),
              onTap: () => Navigator.pop(context, 'decline'),
            ),
          ListTile(
            key: const Key('rc_delete'),
            leading: const Icon(Icons.delete_outline),
            title: Text('rc_delete'.tr),
            onTap: () => Navigator.pop(context, 'delete'),
          ),
        ]),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'confirm':
        await _run(answerReception(slot.id, 'confirm'));
      case 'decline':
        final reason = await showDialog<String>(
          context: context,
          builder: (_) => TextPromptDialog(
              title: 'rc_decline'.tr,
              hint: 'rc_decline_reason'.tr,
              required: true),
        );
        if (reason == null || !mounted) return;
        await _run(answerReception(slot.id, 'decline', reason: reason));
      case 'delete':
        await _run(deleteReceptionSlot(slot.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final desk = _desk;
    final deskTab = _card.manager
        ? 'rc_tab_desk'.tr
        : _card.host
            ? 'rc_tab_day'.tr
            : null;
    final body = _loading && desk == null && _card.hosts.isEmpty
        ? const Center(child: CircularProgressIndicator())
        : _problem != null
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : deskTab == null || desk == null
                ? _bookView()
                : TabBarView(children: [_bookView(), _deskView(desk)]);
    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'rc_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: deskTab == null || desk == null
            ? null
            : TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: [Tab(text: 'rc_tab_book'.tr), Tab(text: deskTab)],
              ),
      ),
      body: body,
    );
    return deskTab == null || desk == null
        ? scaffold
        : DefaultTabController(length: 2, child: scaffold);
  }

  Widget _bookView() {
    final hosts = _card.hosts;
    final free = [
      for (final s in _card.free)
        if (s.host?.id == _host) s
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_card.bookings.isNotEmpty) ...[
            _header('rc_my'.tr),
            for (final s in _card.bookings) _myBooking(s),
          ],
          if (hosts.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Wrap(spacing: 8, runSpacing: 4, children: [
                for (final h in hosts)
                  ChoiceChip(
                    key: Key('rc_host_${h.id}'),
                    label: Text(h.name),
                    selected: _host == h.id,
                    onSelected: (_) => setState(() => _host = h.id),
                  ),
              ]),
            ),
          _header('rc_free'.tr),
          if (free.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('rc_no_free'.tr, textAlign: TextAlign.center),
            )
          else
            for (final s in free)
              ListTile(
                key: Key('rc_slot_${s.id}'),
                leading: const Icon(Icons.event_available_outlined),
                title: Text(_dayTime(s.startsAt)),
                subtitle: Text(s.host?.jobTitle ?? ''),
                onTap: _busy ? null : () => _book(s),
              ),
        ],
      ),
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      );

  Widget _myBooking(ReceptionSlot s) {
    final color = context.readable(_statusColor(s.status));
    return ListTile(
      key: Key('rc_mine_${s.id}'),
      leading: Icon(Icons.event_note_outlined, color: color),
      title: Text('${_dayTime(s.startsAt)} · ${s.host?.name ?? ''}'),
      subtitle: Text([
        s.topic,
        'rc_status_${s.status ?? 'requested'}'.tr,
      ].join('\n')),
      isThreeLine: true,
      trailing: IconButton(
        key: Key('rc_cancel_${s.id}'),
        icon: const Icon(Icons.close),
        tooltip: 'rc_cancel'.tr,
        onPressed: _busy
            ? null
            : () => _run(cancelReception(s.id), done: 'rc_cancelled'.tr),
      ),
    );
  }

  Widget _deskView(List<ReceptionSlot> slots) {
    final hosts = _card.hosts;
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: _card.manager
          ? FloatingActionButton.extended(
              key: const Key('rc_open'),
              onPressed: _busy ? null : _open,
              icon: const Icon(Icons.more_time),
              label: Text('rc_open'.tr),
            )
          : null,
      body: Column(children: [
        DayNavigator(
          date: _day,
          onChanged: (day) {
            setState(() => _day = day);
            _loadDesk();
          },
        ),
        if (_card.manager && hosts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: DropdownButton<String>(
              key: const Key('rc_desk_host'),
              isExpanded: true,
              value: _deskHost ?? hosts.first.id,
              items: [
                for (final h in hosts)
                  DropdownMenuItem(value: h.id, child: Text(h.name)),
              ],
              onChanged: (id) {
                setState(() => _deskHost = id);
                _loadDesk();
              },
            ),
          ),
        Expanded(
          child: slots.isEmpty
              ? ListView(children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child:
                        Text('rc_desk_empty'.tr, textAlign: TextAlign.center),
                  ),
                ])
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: slots.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _deskTile(slots[i]),
                ),
        ),
      ]),
    );
  }

  Widget _deskTile(ReceptionSlot s) {
    final AssignPerson? who = s.employee;
    final color =
        s.booked ? context.readable(_statusColor(s.status)) : Colors.grey;
    return ListTile(
      key: Key('rc_desk_${s.id}'),
      leading: Text(_time(s.startsAt),
          style: TextStyle(fontWeight: FontWeight.w600, color: color)),
      title: Text(who?.name ?? 'rc_free_slot'.tr),
      subtitle: who == null
          ? null
          : Text([
              if (who.department.isNotEmpty) who.department,
              s.topic,
              'rc_status_${s.status ?? 'requested'}'.tr,
            ].join('\n')),
      isThreeLine: who != null,
      onTap: _card.manager && !_busy ? () => _deskSlot(s) : null,
    );
  }
}
