import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/material_pass_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';
import 'material_passes_screen.dart';

/// Один пропуск: что вывозят, кто и когда, код для сверки и история.
///
/// Руководитель согласует или отказывает, охрана выпускает или задерживает,
/// автор отзывает.
class MaterialPassDetailScreen extends StatefulWidget {
  const MaterialPassDetailScreen({Key? key, required this.passId})
      : super(key: key);

  final int passId;

  @override
  State<MaterialPassDetailScreen> createState() =>
      _MaterialPassDetailScreenState();
}

class _MaterialPassDetailScreenState extends State<MaterialPassDetailScreen> {
  MaterialPass? _item;
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
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
      final item = await fetchMaterialPass(widget.passId);
      if (!mounted) return;
      setState(() {
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

  Future<void> _act(String action, {String comment = ''}) async {
    setState(() => _busy = true);
    final result =
        await materialPassAction(widget.passId, action, comment: comment);
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
    for (final key in ['pass_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _actWithText(String action, String hint,
      {bool required = false}) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
          title: 'pass_$action'.tr, hint: hint, required: required),
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
              child: Text('pass_cancel'.tr)),
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
            content: 'pass_number'.trParams({'id': '${widget.passId}'}),
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
                      if (item.code != null &&
                          (item.isAuthor || item.canRelease) &&
                          item.status == 'approved' &&
                          !item.expired) ...[
                        _code(item),
                        const SizedBox(height: 12),
                      ],
                      _header(item),
                      const SizedBox(height: 12),
                      _actions(item),
                      const SizedBox(height: 20),
                      Text('pass_lines'.tr,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      for (var i = 0; i < item.lines.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              SizedBox(
                                  width: 28,
                                  child: Text('${i + 1}.',
                                      style: TextStyle(
                                          color: context.mutedColor))),
                              Expanded(
                                  child: Text(item.lines[i].name,
                                      style: const TextStyle(fontSize: 14))),
                              Text(item.lines[i].amount,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
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

  /// Автору — код, который назовёт водитель; охране — что должно прозвучать.
  Widget _code(MaterialPass item) {
    final color = context.readable(passStatusColor('approved'));
    return Container(
      key: const Key('pass_code'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(
        children: [
          Text('pass_code'.tr, style: TextStyle(color: color)),
          const SizedBox(height: 4),
          Text(item.code!,
              style: TextStyle(
                  fontSize: 36,
                  letterSpacing: 8,
                  fontWeight: FontWeight.w700,
                  color: color)),
          const SizedBox(height: 4),
          Text(
              item.canRelease
                  ? 'pass_code_check'.trParams({'code': item.code!})
                  : 'pass_code_hint'.tr,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
        ],
      ),
    );
  }

  Widget _header(MaterialPass item) {
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    final created = item.createdAt == null
        ? ''
        : DateFormat('dd.MM.yyyy HH:mm').format(item.createdAt!);
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
                  'pass_on_date'.trParams(
                      {'date': DateFormat('dd.MM.yyyy').format(item.exitDate)}),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              PassStatusChip(status: item.shownStatus),
            ],
          ),
          const SizedBox(height: 8),
          Text('${'pass_carrier'.tr}: ${item.carrier}',
              style: const TextStyle(fontSize: 14)),
          if (item.vehicle.isNotEmpty)
            Text(item.vehicle,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SelectableText(item.purpose, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 10),
          Text(
              [
                created,
                if (!item.isAuthor && item.author != null)
                  '${'it_author'.tr}: ${item.author!.name}',
              ].where((s) => s.isNotEmpty).join(' · '),
              style: muted),
          if (item.approver != null) ...[
            const SizedBox(height: 4),
            Text('pass_approver'.trParams({'name': item.approver!.name}),
                style: muted),
          ],
          if (item.guard != null) ...[
            const SizedBox(height: 4),
            Text('pass_guard'.trParams({'name': item.guard!.name}),
                style: muted),
          ],
          if (item.reason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('pass_reason'.trParams({'reason': item.reason}),
                style: TextStyle(
                    fontSize: 13,
                    color: context.readable(passStatusColor(item.status)))),
          ],
        ],
      ),
    );
  }

  Widget _actions(MaterialPass item) {
    final buttons = <Widget>[
      if (item.canApprove)
        ElevatedButton.icon(
          key: const Key('pass_approve'),
          onPressed: _busy ? null : () => _act('approve'),
          icon: const Icon(Icons.check),
          label: Text('pass_approve'.tr),
        ),
      if (item.canApprove)
        OutlinedButton.icon(
          key: const Key('pass_reject'),
          onPressed: _busy
              ? null
              : () =>
                  _actWithText('reject', 'pass_reject_hint'.tr, required: true),
          icon: const Icon(Icons.block),
          label: Text('pass_reject'.tr),
        ),
      if (item.canRelease)
        ElevatedButton.icon(
          key: const Key('pass_release'),
          onPressed: _busy
              ? null
              : () => _actWithText('release', 'pass_release_hint'.tr),
          icon: const Icon(Icons.exit_to_app),
          label: Text('pass_release'.tr),
        ),
      if (item.canRelease)
        OutlinedButton.icon(
          key: const Key('pass_hold'),
          onPressed: _busy
              ? null
              : () => _actWithText('hold', 'pass_hold_hint'.tr, required: true),
          icon: const Icon(Icons.front_hand_outlined),
          label: Text('pass_hold'.tr),
        ),
      if (item.isAuthor && item.isOpen)
        OutlinedButton.icon(
          key: const Key('pass_cancel'),
          onPressed: _busy ? null : _cancel,
          icon: const Icon(Icons.close),
          label: Text('pass_cancel'.tr),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _event(MaterialPassEvent event) {
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
                  '${'pass_ev_${event.action}'.tr}'
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
