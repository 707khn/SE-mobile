import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/business_trip_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'business_trip_detail_screen.dart';

Color businessTripColor(String status) => switch (status) {
      'pending' => const Color(0xFF1565C0),
      'approved' => const Color(0xFF6A1B9A),
      'advanced' => const Color(0xFFE65100),
      'reported' => const Color(0xFF00838F),
      'closed' => const Color(0xFF2E7D32),
      'rejected' => const Color(0xFFC62828),
      _ => const Color(0xFF757575),
    };

class BusinessTripChip extends StatelessWidget {
  const BusinessTripChip({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(businessTripColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('bt_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// «20.01–22.01.2030».
String businessTripDates(BusinessTrip item) {
  final from = item.dateFrom, to = item.dateTo;
  if (from == null || to == null) return '';
  return '${DateFormat('dd.MM').format(from)}–${DateFormat('dd.MM.yyyy').format(to)}';
}

/// Командировки: свои, на согласование и в бухгалтерии.
class BusinessTripsScreen extends StatefulWidget {
  const BusinessTripsScreen({Key? key}) : super(key: key);

  @override
  State<BusinessTripsScreen> createState() => _BusinessTripsScreenState();
}

class _BusinessTripsScreenState extends State<BusinessTripsScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  BusinessTripList _mine = const BusinessTripList(items: []);
  BusinessTripList? _approve;
  BusinessTripList? _accounting;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchBusinessTrips();
      final approve =
          mine.approver ? await fetchBusinessTrips(scope: 'approve') : null;
      final accounting = mine.accountant
          ? await fetchBusinessTrips(scope: 'accounting')
          : null;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _approve = approve;
        _accounting = accounting;
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

  Future<void> _create() async {
    final created =
        await Get.to<BusinessTrip?>(() => const BusinessTripFormScreen());
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('bt_sent'.trParams({'id': '${created.id}'}))));
    _load();
  }

  Future<void> _open(BusinessTrip item) async {
    await Get.to(() => BusinessTripDetailScreen(
        tripId: item.id, dailyAllowance: _mine.dailyAllowance));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    String count(String label, int n) => n > 0 ? '$label ($n)' : label;
    final tabs = <(String, Widget)>[
      if (_approve != null)
        (
          count('bt_tab_approve'.tr, _approve!.items.length),
          _list(_approve!.items, 'bt_empty_approve'.tr, staff: true)
        ),
      if (_accounting != null)
        (
          count('bt_tab_accounting'.tr, _accounting!.items.length),
          _list(_accounting!.items, 'bt_empty_accounting'.tr, staff: true)
        ),
      ('bt_tab_mine'.tr, _list(_mine.items, 'bt_empty_mine'.tr)),
    ];
    final single = _loading || tabs.length == 1;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _problem != null
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : single
                ? tabs.last.$2
                : TabBarView(children: [for (final t in tabs) t.$2]);
    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'bt_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: single
            ? null
            : TabBar(
                isScrollable: tabs.length > 2,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: [for (final t in tabs) Tab(text: t.$1)],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('bt_new'),
        onPressed: _loading ? null : _create,
        icon: const Icon(Icons.add),
        label: Text('bt_new'.tr),
      ),
      body: body,
    );
    return single
        ? scaffold
        : DefaultTabController(
            key: ValueKey(tabs.length), length: tabs.length, child: scaffold);
  }

  Widget _list(List<BusinessTrip> items, String empty, {bool staff = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(empty,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.mutedColor)),
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 8, bottom: 88),
              itemCount: items.length,
              itemBuilder: (_, i) => _row(items[i], staff),
            ),
    );
  }

  Widget _row(BusinessTrip item, bool staff) {
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                        staff
                            ? '${item.employee?.short ?? ''} · ${item.destination}'
                            : item.destination,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  BusinessTripChip(status: item.status),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  '№${item.id}',
                  businessTripDates(item),
                  'bt_transport_${item.transport}'.tr,
                ].where((s) => s.isNotEmpty).join(' · '),
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
              const SizedBox(height: 4),
              Text(item.purpose, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

/// Заявка: куда, зачем, когда, на чём и нужен ли аванс.
class BusinessTripFormScreen extends StatefulWidget {
  const BusinessTripFormScreen({Key? key, this.now}) : super(key: key);

  /// Для проверок: от какого «сегодня» считать сроки по умолчанию.
  final DateTime? now;

  @override
  State<BusinessTripFormScreen> createState() => _BusinessTripFormScreenState();
}

class _BusinessTripFormScreenState extends State<BusinessTripFormScreen> {
  final _destination = TextEditingController();
  final _organization = TextEditingController();
  final _purpose = TextEditingController();
  final _advance = TextEditingController();
  late DateTimeRange _dates;
  String _transport = 'train';
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final now = widget.now ?? DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    _dates = DateTimeRange(
        start: tomorrow, end: tomorrow.add(const Duration(days: 2)));
  }

  @override
  void dispose() {
    for (final c in [_destination, _organization, _purpose, _advance]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _dates,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 366)),
    );
    if (picked != null && mounted) setState(() => _dates = picked);
  }

  String _errorText(String? code) {
    for (final key in ['bt_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _send() async {
    final destination = _destination.text.trim();
    final purpose = _purpose.text.trim();
    if (destination.isEmpty || purpose.isEmpty) {
      setState(() => _error = _errorText(
          destination.isEmpty ? 'destination_required' : 'purpose_required'));
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await requestBusinessTrip(
      destination: destination,
      purpose: purpose,
      dateFrom: _dates.start,
      dateTo: _dates.end,
      organization: _organization.text.trim(),
      transport: _transport,
      advance: _advance.text.trim(),
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(result.item);
      return;
    }
    setState(() {
      _sending = false;
      _error = _errorText(result.error);
    });
  }

  InputDecoration _field(String label) => InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        counterText: '',
      );

  @override
  Widget build(BuildContext context) {
    final days = _dates.end.difference(_dates.start).inDays + 1;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'bt_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            key: const Key('bt_destination'),
            controller: _destination,
            maxLength: 200,
            decoration: _field('bt_destination'.tr),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('bt_organization'),
            controller: _organization,
            maxLength: 200,
            decoration: _field('bt_organization'.tr),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('bt_purpose'),
            controller: _purpose,
            maxLength: 1000,
            minLines: 2,
            maxLines: 5,
            decoration: _field('bt_purpose'.tr),
          ),
          ListTile(
            key: const Key('bt_dates'),
            contentPadding: EdgeInsets.zero,
            title: Text('bt_dates'.tr,
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
            subtitle: Text(
                '${DateFormat('dd.MM.yyyy').format(_dates.start)} – '
                '${DateFormat('dd.MM.yyyy').format(_dates.end)} · '
                '${'bt_days'.trParams({'n': '$days'})}',
                style: const TextStyle(fontSize: 15)),
            trailing: const Icon(Icons.date_range),
            onTap: _pickDates,
          ),
          Text('bt_transport'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final t in tripTransports)
                ChoiceChip(
                  key: Key('bt_transport_$t'),
                  label: Text('bt_transport_$t'.tr),
                  selected: _transport == t,
                  onSelected: (_) => setState(() => _transport = t),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('bt_advance'),
            controller: _advance,
            keyboardType: TextInputType.number,
            decoration: _field('bt_advance'.tr),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('bt_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('bt_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('bt_send'.tr),
            ),
          ),
        ],
      ),
    );
  }
}
