import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/it_request.dart' show ItEvent;
import '../requests/stock_request.dart';
import '../utils/api.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../utils/secure_storage_helper.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'stock_requests_screen.dart';

/// Одна заявка на ТМЦ: позиции, кто собирает, история.
///
/// Кладовщик отмечает галочками, чего нет, и жмёт «Собрано»: автору уходит
/// «можно забирать», а руководству ДМТО — чего не нашлось.
class StockRequestDetailScreen extends StatefulWidget {
  const StockRequestDetailScreen({Key? key, required this.requestId})
      : super(key: key);

  final int requestId;

  @override
  State<StockRequestDetailScreen> createState() =>
      _StockRequestDetailScreenState();
}

class _StockRequestDetailScreenState extends State<StockRequestDetailScreen> {
  StockRequest? _item;
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  String? _me;
  final Set<int> _missing = {};
  final _comment = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  void _take(StockRequest item) {
    _item = item;
    _missing
      ..clear()
      ..addAll(item.lines.where((l) => l.missing).map((l) => l.id));
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final me = await SecureStorageHelper.instance.getEmployeeId() ??
          await employeeIdFromServer();
      final item = await fetchStockRequest(widget.requestId);
      if (!mounted) return;
      setState(() {
        _me = me;
        _take(item);
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

  bool get _staff => _item?.canAct == true;

  /// Галочки «нет» — пока заявку собирают.
  bool get _picking =>
      _staff && (_item?.status == 'new' || _item?.status == 'in_progress');

  String _errorText(String? code) {
    for (final key in ['stock_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _act(String action, {String comment = ''}) async {
    setState(() => _busy = true);
    final result = await stockRequestAction(widget.requestId, action,
        comment: comment,
        missing: action == 'ready' ? _missing.toList() : null);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _take(result.item!);
    });
    if (result.ok) {
      if (action == 'comment') _comment.clear();
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_errorText(result.error))));
  }

  Future<void> _reject() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('it_reject'.tr),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          maxLength: 1000,
          decoration: InputDecoration(hintText: 'it_reject_hint'.tr),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr)),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => TextButton(
              onPressed: value.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text('it_reject'.tr),
            ),
          ),
        ],
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (confirmed == true) await _act('reject', comment: text);
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: 'stock_number'.trParams({'id': '${widget.requestId}'}),
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
                      const SizedBox(height: 12),
                      _linesCard(item),
                      const SizedBox(height: 12),
                      _actions(item),
                      const SizedBox(height: 20),
                      Text('it_history'.tr,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      for (final event in item.events) _event(event),
                      if (item.isOpen) ...[
                        const SizedBox(height: 8),
                        _commentBox(),
                      ],
                    ],
                  ),
                ),
    );
  }

  BoxDecoration get _card => BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: context.cardShadow,
      );

  Widget _header(StockRequest item) {
    final created = item.createdAt == null
        ? ''
        : DateFormat('dd.MM.yyyy HH:mm').format(item.createdAt!);
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(item.purpose,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              StockStatusChip(status: item.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(
              '$created · ${item.warehouse == null ? 'stock_warehouse_any'.tr : 'stock_warehouse_n'.trParams({
                      'n': '${item.warehouse}'
                    })}',
              style: muted),
          if (item.author != null) ...[
            const SizedBox(height: 4),
            Text(
                '${'it_author'.tr}: ${item.author!.name}'
                '${item.author!.department.isEmpty ? '' : ', ${item.author!.department}'}',
                style: muted),
          ],
          if (item.assignee != null) ...[
            const SizedBox(height: 4),
            Text('it_assignee'.trParams({'name': item.assignee!.name}),
                style: muted),
          ],
          if (item.resolution.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(item.resolution,
                style: TextStyle(
                    fontSize: 13,
                    color: context.readable(stockStatusColor(item.status)))),
          ],
        ],
      ),
    );
  }

  Widget _linesCard(StockRequest item) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: _card,
      // Строки списка рисуют отклик на нажатие на ближайшем Material — без
      // своего его закрыл бы фон карточки.
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
              child: Text(
                _picking
                    ? 'stock_ready_hint'.tr
                    : 'stock_lines_count'
                        .trParams({'count': '${item.lines.length}'}),
                style: TextStyle(fontSize: 12, color: context.mutedColor),
              ),
            ),
            for (final line in item.lines)
              _picking
                  ? CheckboxListTile(
                      key: Key('stock_line_${line.id}'),
                      dense: true,
                      value: _missing.contains(line.id),
                      onChanged: _busy
                          ? null
                          : (on) => setState(() => on == true
                              ? _missing.add(line.id)
                              : _missing.remove(line.id)),
                      title: Text(line.name),
                      subtitle: Text(line.amount),
                      secondary: Text('stock_missing'.tr,
                          style: TextStyle(
                              fontSize: 11, color: context.mutedColor)),
                    )
                  : ListTile(
                      dense: true,
                      title: Text(line.name,
                          style: line.missing
                              ? TextStyle(
                                  decoration: TextDecoration.lineThrough,
                                  color: context.mutedColor)
                              : null),
                      trailing: Text(
                          line.missing
                              ? '${line.amount} · ${'stock_missing'.tr}'
                              : line.amount,
                          style: TextStyle(
                              fontSize: 13,
                              color: line.missing
                                  ? context.readable(const Color(0xFFC62828))
                                  : null)),
                    ),
          ],
        ),
      ),
    );
  }

  Widget _actions(StockRequest item) {
    final isAuthor = item.author?.id != null && item.author?.id == _me;
    final buttons = <Widget>[
      if (_staff && item.status == 'new')
        ElevatedButton.icon(
          onPressed: _busy ? null : () => _act('take'),
          icon: const Icon(Icons.pan_tool_alt_outlined),
          label: Text('it_take'.tr),
        ),
      if (_picking)
        ElevatedButton.icon(
          key: const Key('stock_ready'),
          onPressed: _busy || _missing.length == item.lines.length
              ? null
              : () => _act('ready'),
          icon: const Icon(Icons.inventory_outlined),
          label: Text('stock_ready'.tr),
        ),
      if (_staff && item.isOpen)
        ElevatedButton.icon(
          onPressed: _busy ? null : () => _act('issued'),
          icon: const Icon(Icons.check),
          label: Text('stock_issued'.tr),
        ),
      if (_staff && item.isOpen)
        OutlinedButton.icon(
          onPressed: _busy ? null : _reject,
          icon: const Icon(Icons.block),
          label: Text('it_reject'.tr),
        ),
      if (isAuthor && item.isOpen)
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _act('cancel'),
          icon: const Icon(Icons.close),
          label: Text('it_cancel'.tr),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _event(ItEvent event) {
    final when =
        event.at == null ? '' : DateFormat('dd.MM HH:mm').format(event.at!);
    final label = switch (event.action) {
      'ready' => 'stock_ev_ready'.tr,
      'issued' => 'stock_ev_issued'.tr,
      'take' => 'stock_status_in_progress'.tr,
      _ => 'it_ev_${event.action}'.tr,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(when,
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '$label${event.actor == null ? '' : ' · ${event.actor!.short}'}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                if (event.comment.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(event.comment,
                        style: const TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _commentBox() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _comment,
            maxLength: 1000,
            minLines: 1,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: 'it_comment_hint'.tr,
              border: const OutlineInputBorder(),
              isDense: true,
              counterText: '',
            ),
          ),
        ),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _comment,
          builder: (context, value, _) => IconButton(
            icon: const Icon(Icons.send),
            tooltip: 'it_send'.tr,
            onPressed: _busy || value.text.trim().isEmpty
                ? null
                : () => _act('comment', comment: value.text.trim()),
          ),
        ),
      ],
    );
  }
}
