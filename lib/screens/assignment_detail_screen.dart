import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/assignment_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';
import 'assignments_screen.dart';

/// Одно поручение: что, к какому сроку, отчёт и история; кнопки — по роли.
class AssignmentDetailScreen extends StatefulWidget {
  const AssignmentDetailScreen({Key? key, required this.assignmentId})
      : super(key: key);

  final int assignmentId;

  @override
  State<AssignmentDetailScreen> createState() => _AssignmentDetailScreenState();
}

class _AssignmentDetailScreenState extends State<AssignmentDetailScreen> {
  Assignment? _item;
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final item = await fetchAssignment(widget.assignmentId);
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

  Future<String?> _ask(String title, String hint, {bool required = true}) =>
      showDialog<String>(
        context: context,
        builder: (_) =>
            TextPromptDialog(title: title, hint: hint, required: required),
      );

  Future<void> _act(String action) async {
    final item = _item;
    if (item == null) return;
    var comment = '';
    DateTime? due;
    switch (action) {
      case 'done':
        final text = await _ask('asg_done'.tr, 'asg_done_hint'.tr);
        if (text == null) return;
        comment = text;
      case 'return':
        final text = await _ask('asg_return'.tr, 'asg_return_hint'.tr);
        if (text == null) return;
        comment = text;
      case 'comment':
        final text = await _ask('asg_comment'.tr, 'asg_comment_hint'.tr);
        if (text == null) return;
        comment = text;
      case 'cancel':
        final text =
            await _ask('asg_cancel'.tr, 'asg_cancel_hint'.tr, required: false);
        if (text == null) return;
        comment = text;
      case 'extend':
        final from = item.dueDate.add(const Duration(days: 1));
        due = await showDatePicker(
          context: context,
          initialDate: from.add(const Duration(days: 6)),
          firstDate: from,
          lastDate: from.add(const Duration(days: 365)),
        );
        if (due == null || !mounted) return;
        final text = await _ask('asg_extend'.tr, 'asg_extend_hint'.tr);
        if (text == null) return;
        comment = text;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final result = await assignmentAction(widget.assignmentId, action,
        comment: comment, dueDate: due);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    final messenger = ScaffoldMessenger.of(context);
    if (result.ok) {
      if (action == 'remind') {
        messenger.showSnackBar(SnackBar(content: Text('asg_reminded'.tr)));
      }
      return;
    }
    final code = result.error;
    final key = 'asg_err_$code';
    messenger.showSnackBar(SnackBar(
        content:
            Text(code != null && key.tr != key ? key.tr : 'it_err_failed'.tr)));
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: 'asg_number'.trParams({'id': '${widget.assignmentId}'}),
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
                      if (item.proposedDue != null) ...[
                        const SizedBox(height: 12),
                        _note(
                            Icons.schedule,
                            'asg_proposed'.trParams({
                              'date': DateFormat('dd.MM.yyyy')
                                  .format(item.proposedDue!),
                              'reason': item.proposedReason,
                            }),
                            const Color(0xFFE65100)),
                      ],
                      if (item.result.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _note(
                            Icons.assignment_turned_in_outlined,
                            '${'asg_result'.tr}: ${item.result}',
                            const Color(0xFF6A1B9A)),
                      ],
                      const SizedBox(height: 16),
                      ..._buttons(item),
                      const SizedBox(height: 20),
                      Text('asg_history'.tr,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      for (final e in item.events) _event(e),
                    ],
                  ),
                ),
    );
  }

  Widget _header(Assignment item) {
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(item.title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              AssignmentStatusChip(status: item.status),
            ],
          ),
          if (item.important) ...[
            const SizedBox(height: 4),
            Text('asg_important'.tr,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.readable(const Color(0xFFC62828)))),
          ],
          if (item.text.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(item.text, style: const TextStyle(fontSize: 14)),
          ],
          const SizedBox(height: 8),
          Text(assignmentDueLabel(item),
              key: const Key('asg_due_label'),
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: item.overdue ? FontWeight.w600 : null,
                  color: item.overdue
                      ? context.readable(const Color(0xFFC62828))
                      : null)),
          const SizedBox(height: 4),
          if (item.author != null && !item.isAuthor)
            Text('asg_from'.trParams({'name': item.author!.name}),
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
          if (item.assignee != null && !item.isAssignee)
            Text('asg_to'.trParams({'name': item.assignee!.name}),
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
        ],
      ),
    );
  }

  Widget _note(IconData icon, String text, Color color) {
    final shade = context.readable(color);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: shade.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: shade),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(text)),
        ],
      ),
    );
  }

  List<Widget> _buttons(Assignment item) {
    if (item.isClosed) return const [];
    Widget main(String action, IconData icon) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: Key('asg_$action'),
              onPressed: _busy ? null : () => _act(action),
              icon: Icon(icon),
              label: Text('asg_$action'.tr),
            ),
          ),
        );
    Widget side(String action, IconData icon) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: OutlinedButton.icon(
            key: Key('asg_$action'),
            onPressed: _busy ? null : () => _act(action),
            icon: Icon(icon),
            label: Text('asg_$action'.tr),
          ),
        );
    return [
      if (item.isAssignee && item.status == 'new')
        main('accept', Icons.play_arrow),
      if (item.isAssignee && item.isOpen) main('done', Icons.done_all),
      if (item.isAuthor && item.status == 'done') ...[
        main('close', Icons.verified_outlined),
        side('return', Icons.undo),
      ],
      if (item.isAuthor && item.proposedDue != null) ...[
        main('extend_ok', Icons.event_available),
        side('extend_no', Icons.event_busy),
      ],
      if (item.isAssignee && item.isOpen && item.proposedDue == null)
        side('extend', Icons.schedule),
      if (item.isAuthor && item.canRemind)
        side('remind', Icons.notifications_active_outlined),
      side('comment', Icons.chat_bubble_outline),
      if (item.isAuthor) side('cancel', Icons.close),
    ];
  }

  Widget _event(AssignmentEvent e) {
    final when = e.at == null ? '' : DateFormat('dd.MM HH:mm').format(e.at!);
    final due = e.due == null ? '' : ' → ${DateFormat('dd.MM').format(e.due!)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$when · ${e.actor?.short ?? ''} ${'asg_ev_${e.action}'.tr}$due',
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          if (e.comment.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(e.comment, style: const TextStyle(fontSize: 14)),
            ),
        ],
      ),
    );
  }
}
