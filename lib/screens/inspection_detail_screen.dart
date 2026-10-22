import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/inspection_request.dart';
import '../utils/api.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../utils/secure_storage_helper.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'inspections_screen.dart';
import 'repair_requests_screen.dart' show repairDowntimeLabel;

/// Одно предъявление: партия, кто проверяет, причина возврата и история.
///
/// Проверяющий текущего шага берёт, принимает или возвращает с причиной,
/// автор после возврата предъявляет повторно или отменяет.
class InspectionDetailScreen extends StatefulWidget {
  const InspectionDetailScreen({Key? key, required this.inspectionId})
      : super(key: key);

  final int inspectionId;

  @override
  State<InspectionDetailScreen> createState() => _InspectionDetailScreenState();
}

class _InspectionDetailScreenState extends State<InspectionDetailScreen> {
  Inspection? _item;
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  String? _me;
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

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final me = await SecureStorageHelper.instance.getEmployeeId() ??
          await employeeIdFromServer();
      final item = await fetchInspection(widget.inspectionId);
      if (!mounted) return;
      setState(() {
        _me = me;
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

  bool get _isAuthor => _item?.author?.id != null && _item?.author?.id == _me;

  Future<void> _act(String action, {String comment = ''}) async {
    setState(() => _busy = true);
    final result =
        await inspectionAction(widget.inspectionId, action, comment: comment);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    if (result.ok) {
      if (action == 'comment') _comment.clear();
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_errorText(result.error))));
  }

  String _errorText(String? code) {
    for (final key in ['insp_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _actWithText(String action, String title, String hint,
      {bool required = false}) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) =>
          _TextDialog(title: title, hint: hint, required: required),
    );
    if (text != null) await _act(action, comment: text);
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('it_cancel_confirm'.tr),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('insp_cancel'.tr)),
        ],
      ),
    );
    if (confirmed == true) await _act('cancel');
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: 'insp_number'.trParams({'id': '${widget.inspectionId}'}),
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

  Widget _header(Inspection item) {
    final created = item.createdAt == null
        ? ''
        : DateFormat('dd.MM.yyyy HH:mm').format(item.createdAt!);
    final hours = item.waitingHours(DateTime.now());
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
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
                child: Text(
                  '${item.product} — ${'insp_pcs'.trParams({
                        'n': '${item.quantity}'
                      })}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              InspectionStatusChip(status: item.status),
            ],
          ),
          const SizedBox(height: 8),
          Text('${'insp_place'.tr}: ${item.place}',
              style: const TextStyle(fontSize: 14)),
          if (item.orderNo.isNotEmpty)
            Text(item.orderNo, style: const TextStyle(fontSize: 14)),
          if (item.note.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(item.note, style: const TextStyle(fontSize: 14)),
          ],
          const SizedBox(height: 10),
          Text(
              [
                created,
                if (item.needsVp) 'insp_needs_vp'.tr,
                if (item.returns > 0)
                  'insp_returns'.trParams({'n': '${item.returns}'}),
              ].where((s) => s.isNotEmpty).join(' · '),
              style: muted),
          if (hours != null) ...[
            const SizedBox(height: 4),
            Text(
              'insp_waiting'.trParams({'time': repairDowntimeLabel(hours)}),
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.readable(inspectionStatusColor(item.status))),
            ),
          ],
          if (!_isAuthor && item.author != null) ...[
            const SizedBox(height: 4),
            Text(
              '${'it_author'.tr}: ${item.author!.name}'
              '${item.author!.department.isEmpty ? '' : ', ${item.author!.department}'}',
              style: muted,
            ),
          ],
          if (item.otk != null) ...[
            const SizedBox(height: 4),
            Text('insp_otk'.trParams({'name': item.otk!.name}), style: muted),
          ],
          if (item.vp != null) ...[
            const SizedBox(height: 4),
            Text('insp_vp'.trParams({'name': item.vp!.name}), style: muted),
          ],
          if (item.status == 'returned' && item.returnReason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
                'insp_return_reason'.trParams({'reason': item.returnReason}),
                key: const Key('insp_return_reason'),
                style: TextStyle(
                    fontSize: 13,
                    color:
                        context.readable(inspectionStatusColor('returned')))),
          ],
        ],
      ),
    );
  }

  Widget _actions(Inspection item) {
    final checker = item.canAct && item.inFlight;
    final buttons = <Widget>[
      if (checker && item.status.startsWith('waiting'))
        ElevatedButton.icon(
          key: const Key('insp_take'),
          onPressed: _busy ? null : () => _act('take'),
          icon: const Icon(Icons.pan_tool_alt_outlined),
          label: Text('insp_take'.tr),
        ),
      if (checker)
        ElevatedButton.icon(
          key: const Key('insp_accept'),
          onPressed: _busy ? null : () => _act('accept'),
          icon: const Icon(Icons.verified_outlined),
          label: Text('insp_accept'.tr),
        ),
      if (checker)
        OutlinedButton.icon(
          key: const Key('insp_return'),
          onPressed: _busy
              ? null
              : () => _actWithText(
                  'return', 'insp_return'.tr, 'insp_return_hint'.tr,
                  required: true),
          icon: const Icon(Icons.undo),
          label: Text('insp_return'.tr),
        ),
      if (_isAuthor && item.status == 'returned')
        ElevatedButton.icon(
          key: const Key('insp_resubmit'),
          onPressed: _busy
              ? null
              : () => _actWithText(
                  'resubmit', 'insp_resubmit'.tr, 'insp_resubmit_hint'.tr),
          icon: const Icon(Icons.replay),
          label: Text('insp_resubmit'.tr),
        ),
      if (_isAuthor && item.isOpen)
        OutlinedButton.icon(
          key: const Key('insp_cancel'),
          onPressed: _busy ? null : _cancel,
          icon: const Icon(Icons.close),
          label: Text('insp_cancel'.tr),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  String _eventLabel(InspectionEvent event) {
    final staged = const {'take', 'accept', 'return'}.contains(event.action) &&
        event.stage.isNotEmpty;
    final key = staged
        ? 'insp_ev_${event.action}_${event.stage}'
        : 'insp_ev_${event.action}';
    return key.tr;
  }

  Widget _event(InspectionEvent event) {
    final when =
        event.at == null ? '' : DateFormat('dd.MM HH:mm').format(event.at!);
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
                  '${_eventLabel(event)}'
                  '${event.actor == null ? '' : ' · ${event.actor!.short}'}',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
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

/// Причина возврата или «что доработали». Поле живёт в самом диалоге:
/// контроллер, закрытый сразу после pop, ломает анимацию закрытия.
class _TextDialog extends StatefulWidget {
  const _TextDialog(
      {required this.title, required this.hint, required this.required});

  final String title;
  final String hint;
  final bool required;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('insp_dialog_text'),
        controller: _text,
        autofocus: true,
        maxLines: 3,
        maxLength: 1000,
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _text,
          builder: (context, value, _) => TextButton(
            key: const Key('insp_dialog_ok'),
            onPressed: widget.required && value.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, value.text.trim()),
            child: Text(widget.title),
          ),
        ),
      ],
    );
  }
}
