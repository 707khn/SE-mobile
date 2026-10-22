import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../requests/hr_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'hr_requests_screen.dart';

/// Очередь заявок для отдела кадров: принять, отметить готовой (и где
/// забрать), выдать, отклонить с причиной. Сотрудник видит каждый шаг у себя.
class HrQueueScreen extends StatefulWidget {
  const HrQueueScreen({Key? key}) : super(key: key);

  @override
  State<HrQueueScreen> createState() => _HrQueueScreenState();
}

/// Где кадры обычно выдают документы — подставляется в «готова», чтобы не
/// набирать каждый раз.
const _pickupKey = 'hr_pickup_place';

class _HrQueueScreenState extends State<HrQueueScreen> {
  static const _filters = ['open', 'new', 'accepted', 'ready', 'all'];

  String _filter = 'open';
  bool _loading = true;
  List<HrRequest> _items = [];
  Map<String, int> _counts = {};
  LoadProblem? _problem;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final result = await getHrQueue(status: _filter);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _problem = result.problem;
      if (!result.failed) {
        _items = result.items;
        _counts = result.counts;
      }
    });
  }

  Future<String?> _askNote(String status) async {
    String initial = '';
    if (status == 'ready') {
      try {
        final prefs = await SharedPreferences.getInstance();
        initial = prefs.getString(_pickupKey) ?? '';
      } catch (_) {}
    }
    if (!mounted) return null;
    final controller = TextEditingController(text: initial);
    final rejecting = status == 'rejected';
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(rejecting ? 'hr_reject_title'.tr : 'hr_ready_title'.tr),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 2,
          maxLength: 500,
          decoration: InputDecoration(
            hintText: rejecting ? 'hr_reject_hint'.tr : 'hr_ready_hint'.tr,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('cancel'.tr)),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            // Отказ без причины — это звонок в кадры с вопросом «почему».
            builder: (context, value, _) => TextButton(
              onPressed: rejecting && value.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, value.text.trim()),
              child: Text('hr_step_$status'.tr),
            ),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note != null && status == 'ready' && note.isNotEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_pickupKey, note);
      } catch (_) {}
    }
    return note;
  }

  Future<void> _step(HrRequest item, String status) async {
    String note = '';
    if (status == 'ready' || status == 'rejected') {
      final asked = await _askNote(status);
      if (asked == null) return;
      note = asked;
    }
    setState(() => _busy.add(item.id));
    final result = await setHrRequestStatus(item.id, status, note: note);
    if (!mounted) return;
    setState(() => _busy.remove(item.id));
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(result.error == 'bad_status'
              ? 'hr_changed_meanwhile'.tr
              : 'hr_save_failed'.tr)));
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final failed = _problem != null && _items.isEmpty;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'hr_queue'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                  horizontal: Dimensions.width20, vertical: 8),
              children: [
                for (final f in _filters)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_filterLabel(f)),
                      selected: _filter == f,
                      onSelected: (_) {
                        if (_filter == f) return;
                        setState(() => _filter = f);
                        _load();
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _loading && _items.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : failed
                    ? LoadErrorView(problem: _problem, onRetry: _load)
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: _items.isEmpty
                            ? ListView(
                                physics: const AlwaysScrollableScrollPhysics(),
                                children: [
                                  Padding(
                                    padding: EdgeInsets.all(Dimensions.height30),
                                    child: Center(child: Text('hr_queue_empty'.tr)),
                                  ),
                                ],
                              )
                            : ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.only(bottom: 24),
                                itemCount: _items.length,
                                itemBuilder: (_, i) => _card(_items[i]),
                              ),
                      ),
          ),
        ],
      ),
    );
  }

  String _filterLabel(String f) {
    final label = f == 'open' ? 'hr_filter_open'.tr
        : f == 'all' ? 'hr_filter_all'.tr
        : hrStatusKey(f).tr;
    final count = f == 'open'
        ? _counts.values.fold<int>(0, (a, b) => a + b)
        : _counts[f];
    return count == null || count == 0 ? label : '$label · $count';
  }

  Widget _card(HrRequest item) {
    final steps = item.nextSteps;
    final busy = _busy.contains(item.id);
    return HrRequestCard(
      item: item,
      showEmployee: true,
      actions: steps.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 4),
              child: busy
                  ? const LinearProgressIndicator()
                  : Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final s in steps)
                          s == 'rejected'
                              ? TextButton(
                                  onPressed: () => _step(item, s),
                                  style: TextButton.styleFrom(
                                      foregroundColor: Colors.red.shade700),
                                  child: Text('hr_step_$s'.tr),
                                )
                              : FilledButton.tonal(
                                  onPressed: () => _step(item, s),
                                  child: Text('hr_step_$s'.tr),
                                ),
                      ],
                    ),
            ),
    );
  }
}
