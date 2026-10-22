import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/material_pass_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'material_pass_detail_screen.dart';
import 'material_pass_form_screen.dart';

Color passStatusColor(String status) => switch (status) {
      'pending' => const Color(0xFF1565C0),
      'approved' => const Color(0xFF2E7D32),
      'released' => const Color(0xFF546E7A),
      'rejected' || 'held' => const Color(0xFFC62828),
      'expired' => const Color(0xFFE65100),
      _ => const Color(0xFF757575),
    };

class PassStatusChip extends StatelessWidget {
  const PassStatusChip({Key? key, required this.status}) : super(key: key);

  /// Как в [MaterialPass.shownStatus]: просроченный — «expired».
  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(passStatusColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('pass_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Материальные пропуска: свои, у руководителя — на согласование, у
/// охраны — согласованные на сегодня и поиск по номеру.
class MaterialPassesScreen extends StatefulWidget {
  const MaterialPassesScreen({Key? key}) : super(key: key);

  @override
  State<MaterialPassesScreen> createState() => _MaterialPassesScreenState();
}

class _MaterialPassesScreenState extends State<MaterialPassesScreen> {
  bool _loading = true;
  bool _failed = false;
  LoadProblem? _problem;
  MaterialPassList _mine = const MaterialPassList(items: []);
  MaterialPassList? _approve;
  MaterialPassList? _gate;
  final _find = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _find.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchMaterialPasses();
      final approve =
          mine.approver ? await fetchMaterialPasses(scope: 'approve') : null;
      final gate = mine.guard ? await fetchMaterialPasses(scope: 'gate') : null;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _approve = approve;
        _gate = gate;
        _failed = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _problem = problemOfAny(e);
        _loading = false;
      });
    }
  }

  Future<void> _create() async {
    final created =
        await Get.to<MaterialPass?>(() => const MaterialPassFormScreen());
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('it_sent'.trParams({'id': '${created.id}'}))));
    _load();
  }

  Future<void> _openId(int id) async {
    await Get.to(() => MaterialPassDetailScreen(passId: id));
    if (mounted) _load();
  }

  void _findById() {
    final id = int.tryParse(_find.text.trim().replaceAll(RegExp(r'\D'), ''));
    if (id == null) return;
    _find.clear();
    _openId(id);
  }

  @override
  Widget build(BuildContext context) {
    final gate = _gate;
    final approve = _approve;
    final tabs = <(String, Widget)>[
      if (gate != null)
        (
          'pass_gate_tab'.tr,
          Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                key: const Key('pass_find'),
                controller: _find,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _findById(),
                decoration: InputDecoration(
                  labelText: 'pass_find'.tr,
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: _findById,
                  ),
                ),
              ),
            ),
            Expanded(child: _list(gate.items, 'pass_empty_gate'.tr)),
          ])
        ),
      if (approve != null)
        (
          approve.pending > 0
              ? '${'pass_approve_tab'.tr} (${approve.pending})'
              : 'pass_approve_tab'.tr,
          _list(approve.items, 'pass_empty_approve'.tr, showAuthor: true)
        ),
      ('pass_mine'.tr, _list(_mine.items, 'pass_empty_mine'.tr)),
    ];
    final many = !_loading && !_failed && tabs.length > 1;
    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'pass_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: many
            ? TabBar(
                isScrollable: tabs.length > 2,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: [for (final t in tabs) Tab(text: t.$1)],
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: Text('pass_new'.tr),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : many
                  ? TabBarView(children: [for (final t in tabs) t.$2])
                  : tabs.last.$2,
    );
    return many
        ? DefaultTabController(
            key: ValueKey(tabs.length), length: tabs.length, child: scaffold)
        : scaffold;
  }

  Widget _list(List<MaterialPass> items, String empty,
      {bool showAuthor = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.local_shipping_outlined,
                    size: 56, color: context.mutedColor),
                const SizedBox(height: 12),
                Text(empty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.mutedColor)),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              itemCount: items.length,
              itemBuilder: (_, i) => _row(items[i], showAuthor),
            ),
    );
  }

  Widget _row(MaterialPass item, bool showAuthor) {
    final first = item.lines.isEmpty ? '' : item.lines.first.name;
    final more = item.lines.length > 1 ? ' +${item.lines.length - 1}' : '';
    final highlight = item.canApprove || item.canRelease;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: highlight
            ? Border(
                left: BorderSide(
                    color: passStatusColor(item.shownStatus), width: 3))
            : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _openId(item.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.local_shipping_outlined, color: context.mutedColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('№${item.id} · ${item.carrier}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                        PassStatusChip(status: item.shownStatus),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text('$first$more',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(
                      [
                        'pass_on_date'.trParams({
                          'date': DateFormat('dd.MM').format(item.exitDate)
                        }),
                        if (item.vehicle.isNotEmpty) item.vehicle,
                        if (showAuthor && item.author != null)
                          item.author!.short,
                      ].join(' · '),
                      style:
                          TextStyle(fontSize: 11, color: context.mutedColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
