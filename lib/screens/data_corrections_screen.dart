import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/data_correction_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'data_correction_detail_screen.dart';

Color dataCorrectionColor(String status) => switch (status) {
      'new' => const Color(0xFF1565C0),
      'in_work' => const Color(0xFFE65100),
      'done' => const Color(0xFF2E7D32),
      'rejected' => const Color(0xFFC62828),
      _ => const Color(0xFF757575),
    };

class DataCorrectionChip extends StatelessWidget {
  const DataCorrectionChip({Key? key, required this.status}) : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(dataCorrectionColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('dc_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Свои просьбы исправить данные, а у отдела кадров — ещё и очередь.
class DataCorrectionsScreen extends StatefulWidget {
  const DataCorrectionsScreen({Key? key}) : super(key: key);

  @override
  State<DataCorrectionsScreen> createState() => _DataCorrectionsScreenState();
}

class _DataCorrectionsScreenState extends State<DataCorrectionsScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  DataCorrectionList _mine = const DataCorrectionList(items: []);
  DataCorrectionList? _queue;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchDataCorrections();
      final queue = mine.staff ? await fetchDataCorrections(queue: true) : null;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _queue = queue;
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
    final created = await Get.to<DataCorrection?>(
        () => DataCorrectionFormScreen(profile: _mine.profile));
    if (created == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('dc_sent'.trParams({'id': '${created.id}'}))));
    _load();
  }

  Future<void> _open(DataCorrection item) async {
    await Get.to(() => DataCorrectionDetailScreen(correctionId: item.id));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _problem != null
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : queue == null
                ? _list(_mine.items, 'dc_empty_mine'.tr, intro: true)
                : TabBarView(children: [
                    _list(queue.items, 'dc_empty_queue'.tr, staff: true),
                    _list(_mine.items, 'dc_empty_mine'.tr, intro: true),
                  ]);
    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'dc_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: queue == null
            ? null
            : TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: [
                  Tab(
                      text: queue.waiting > 0
                          ? '${'dc_tab_queue'.tr} (${queue.waiting})'
                          : 'dc_tab_queue'.tr),
                  Tab(text: 'dc_tab_mine'.tr),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('dc_new'),
        onPressed: _loading ? null : _create,
        icon: const Icon(Icons.edit_note),
        label: Text('dc_new'.tr),
      ),
      body: body,
    );
    return queue == null
        ? scaffold
        : DefaultTabController(length: 2, child: scaffold);
  }

  Widget _list(List<DataCorrection> items, String empty,
      {bool staff = false, bool intro = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8, bottom: 88),
        children: [
          if (intro)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text('dc_intro'.tr,
                  style: TextStyle(color: context.mutedColor)),
            ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text(empty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.mutedColor)),
            ),
          for (final item in items) _row(item, staff),
        ],
      ),
    );
  }

  Widget _row(DataCorrection item, bool staff) {
    final when = item.createdAt == null
        ? ''
        : DateFormat('dd.MM.yy').format(item.createdAt!);
    final waiting = staff ? item.status == 'new' : false;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: waiting
            ? Border(
                left: BorderSide(
                    color: dataCorrectionColor(item.status), width: 3))
            : null,
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
                            ? (item.author?.name ?? '')
                            : 'dc_kind_${item.kind}'.tr,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  DataCorrectionChip(status: item.status),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  if (staff) 'dc_kind_${item.kind}'.tr,
                  '№${item.id}',
                  if (when.isNotEmpty) when,
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
              const SizedBox(height: 4),
              Text(item.requested,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

/// Что не так, что записано сейчас и как правильно.
class DataCorrectionFormScreen extends StatefulWidget {
  const DataCorrectionFormScreen({Key? key, this.profile = const {}})
      : super(key: key);

  /// name, job, department — что записано о человеке сейчас.
  final Map<String, String> profile;

  @override
  State<DataCorrectionFormScreen> createState() =>
      _DataCorrectionFormScreenState();
}

class _DataCorrectionFormScreenState extends State<DataCorrectionFormScreen> {
  final _requested = TextEditingController();
  final _comment = TextEditingController();
  String _kind = 'name';
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _requested.dispose();
    _comment.dispose();
    super.dispose();
  }

  String get _current => widget.profile[_kind] ?? '';

  String _errorText(String? code) {
    for (final key in ['dc_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _send() async {
    final requested = _requested.text.trim();
    if (requested.isEmpty) {
      setState(() => _error = 'dc_err_requested_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await askDataCorrection(
        kind: _kind, requested: requested, comment: _comment.text.trim());
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

  @override
  Widget build(BuildContext context) {
    final current = _current;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'dc_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text('dc_kind'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final kind in dataCorrectionKinds)
                ChoiceChip(
                  key: Key('dc_kind_$kind'),
                  label: Text('dc_kind_$kind'.tr),
                  selected: _kind == kind,
                  onSelected: (_) => setState(() => _kind = kind),
                ),
            ],
          ),
          if (current.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('dc_current'.tr,
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
            const SizedBox(height: 2),
            Text(current,
                key: const Key('dc_current'),
                style: const TextStyle(fontSize: 15)),
          ],
          const SizedBox(height: 16),
          TextField(
            key: const Key('dc_requested'),
            controller: _requested,
            maxLength: 1000,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              labelText: 'dc_requested'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('dc_comment_field'),
            controller: _comment,
            maxLength: 1000,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: 'dc_comment'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 4),
          Text('dc_note'.tr,
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('dc_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('dc_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('dc_send'.tr),
            ),
          ),
        ],
      ),
    );
  }
}
