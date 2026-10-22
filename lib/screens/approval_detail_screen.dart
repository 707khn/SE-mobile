import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/approval_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';
import 'approvals_screen.dart';
import 'repair_requests_screen.dart' show repairDowntimeLabel;

/// Один лист: что за документ, маршрут с отметками и история.
///
/// Согласующий своего шага согласует (можно с замечаниями) или возвращает,
/// автор отправляет снова, отзывает или напоминает тому, у кого лист лежит.
class ApprovalDetailScreen extends StatefulWidget {
  const ApprovalDetailScreen({Key? key, required this.approvalId})
      : super(key: key);

  final int approvalId;

  @override
  State<ApprovalDetailScreen> createState() => _ApprovalDetailScreenState();
}

class _ApprovalDetailScreenState extends State<ApprovalDetailScreen> {
  Approval? _item;
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
      final item = await fetchApproval(widget.approvalId);
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
        await approvalAction(widget.approvalId, action, comment: comment);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    if (result.ok) {
      if (action == 'comment') _comment.clear();
      if (action == 'remind') {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('appr_reminded'.tr)));
      }
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(_errorText(result.error))));
  }

  String _errorText(String? code) {
    for (final key in ['appr_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _actWithText(String action, String title, String hint,
      {bool required = false}) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) =>
          TextPromptDialog(title: title, hint: hint, required: required),
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
              child: Text('appr_cancel'.tr)),
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
            content: 'appr_number'.trParams({'id': '${widget.approvalId}'}),
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
                      Text('appr_route'.tr,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      for (final step in item.steps) _step(item, step),
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

  Widget _header(Approval item) {
    final created = item.createdAt == null
        ? ''
        : DateFormat('dd.MM.yyyy HH:mm').format(item.createdAt!);
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
              Icon(approvalKindIcon(item.kind), color: context.mutedColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text('appr_kind_${item.kind}'.tr,
                    style: TextStyle(fontSize: 13, color: context.mutedColor)),
              ),
              ApprovalStatusChip(status: item.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(item.title,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          if (item.docNumber.isNotEmpty)
            Text('№ ${item.docNumber}', style: const TextStyle(fontSize: 14)),
          if (item.counterparty.isNotEmpty || item.amount.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
                [item.counterparty, item.amount]
                    .where((s) => s.isNotEmpty)
                    .join(' · '),
                style: const TextStyle(fontSize: 14)),
          ],
          const SizedBox(height: 10),
          SelectableText(item.summary, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 10),
          Text(
              [
                created,
                if (!item.isAuthor && item.author != null)
                  '${'it_author'.tr}: ${item.author!.name}',
              ].where((s) => s.isNotEmpty).join(' · '),
              style: muted),
        ],
      ),
    );
  }

  Widget _actions(Approval item) {
    final buttons = <Widget>[
      if (item.myTurn)
        ElevatedButton.icon(
          key: const Key('appr_approve'),
          onPressed: _busy
              ? null
              : () => _actWithText(
                  'approve', 'appr_approve'.tr, 'appr_approve_hint'.tr),
          icon: const Icon(Icons.check),
          label: Text('appr_approve'.tr),
        ),
      if (item.myTurn)
        OutlinedButton.icon(
          key: const Key('appr_return'),
          onPressed: _busy
              ? null
              : () => _actWithText(
                  'return', 'appr_return'.tr, 'appr_return_hint'.tr,
                  required: true),
          icon: const Icon(Icons.undo),
          label: Text('appr_return'.tr),
        ),
      if (item.isAuthor && item.status == 'returned')
        ElevatedButton.icon(
          key: const Key('appr_resubmit'),
          onPressed: _busy
              ? null
              : () => _actWithText(
                  'resubmit', 'appr_resubmit'.tr, 'appr_resubmit_hint'.tr),
          icon: const Icon(Icons.replay),
          label: Text('appr_resubmit'.tr),
        ),
      if (item.isAuthor && item.status == 'on_route')
        OutlinedButton.icon(
          key: const Key('appr_remind'),
          onPressed: _busy || !item.canRemind ? null : () => _act('remind'),
          icon: const Icon(Icons.notifications_active_outlined),
          label: Text('appr_remind'.tr),
        ),
      if (item.isAuthor && item.isOpen)
        OutlinedButton.icon(
          key: const Key('appr_cancel'),
          onPressed: _busy ? null : _cancel,
          icon: const Icon(Icons.close),
          label: Text('appr_cancel'.tr),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _step(Approval item, ApprovalStep step) {
    final isCurrent = item.isOpen && item.current?.id == step.person.id &&
        step.decision == 'pending';
    final (icon, color) = switch (step.decision) {
      'approved' => (Icons.check_circle, const Color(0xFF2E7D32)),
      'returned' => (Icons.undo, const Color(0xFFC62828)),
      _ when isCurrent => (Icons.hourglass_top, approvalStatusColor('on_route')),
      _ => (Icons.radio_button_unchecked, context.mutedColor),
    };
    final hours = isCurrent ? item.waitingHours(DateTime.now()) : null;
    final stale = isCurrent && item.isStale(DateTime.now());
    final when = step.decidedAt == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(step.decidedAt!);
    final status = [
      if (step.decision != 'pending') 'appr_decision_${step.decision}'.tr,
      if (step.decision == 'approved' && step.comment.isNotEmpty)
        'appr_with_remarks'.tr,
      if (when.isNotEmpty) when,
      if (hours != null)
        'appr_waiting'.trParams({'time': repairDowntimeLabel(hours)}),
      if (stale) 'appr_stale'.tr,
    ].join(' · ');
    return Padding(
      key: Key('appr_route_${step.person.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: context.readable(color)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.person.name,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            isCurrent ? FontWeight.w700 : FontWeight.w500)),
                if (step.person.title.isNotEmpty)
                  Text(step.person.title,
                      style:
                          TextStyle(fontSize: 12, color: context.mutedColor)),
                if (status.isNotEmpty)
                  Text(status,
                      style: TextStyle(
                          fontSize: 12,
                          color: stale
                              ? context.readable(approvalStaleColor)
                              : context.readable(color),
                          fontWeight: stale ? FontWeight.w600 : null)),
                if (step.comment.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(step.comment,
                        style: const TextStyle(fontSize: 13)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _event(ApprovalEvent event) {
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
                  '${'appr_ev_${event.action}'.tr}'
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
