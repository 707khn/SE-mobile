import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/it_request.dart' show ItPerson;
import '../requests/work_permit_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';
import 'work_permits_screen.dart';

/// Наряд: место, время, люди, меры; кнопки — по роли и этапу.
class WorkPermitDetailScreen extends StatefulWidget {
  const WorkPermitDetailScreen({Key? key, required this.permitId})
      : super(key: key);

  final int permitId;

  @override
  State<WorkPermitDetailScreen> createState() => _WorkPermitDetailScreenState();
}

class _WorkPermitDetailScreenState extends State<WorkPermitDetailScreen> {
  WorkPermit? _item;
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
      final item = await fetchWorkPermit(widget.permitId);
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

  static const _asks = {'approve', 'reject', 'close', 'stop', 'comment'};
  static const _required = {'reject', 'stop', 'comment'};

  Future<void> _act(String action) async {
    var text = '';
    if (_asks.contains(action)) {
      final entered = await showDialog<String>(
        context: context,
        builder: (_) => TextPromptDialog(
            title: 'wp_$action'.tr,
            hint: 'wp_${action}_hint'.tr,
            required: _required.contains(action)),
      );
      if (entered == null || !mounted) return;
      text = entered;
    }
    setState(() => _busy = true);
    final result = await workPermitAction(widget.permitId, action, text: text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    if (result.ok) return;
    final code = result.error;
    final key = 'wp_err_$code';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
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
            content: 'wp_number'.trParams({'id': '${widget.permitId}'}),
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
                      if (item.overdue || item.expired) ...[
                        const SizedBox(height: 12),
                        _banner(
                            item.overdue ? 'wp_overdue'.tr : 'wp_expired'.tr,
                            const Color(0xFFC62828),
                            key: const Key('wp_alarm')),
                      ],
                      if (item.reason.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _banner('${'wp_reason'.tr}: ${item.reason}',
                            workPermitColor(item.status)),
                      ],
                      const SizedBox(height: 12),
                      _people(item),
                      const SizedBox(height: 12),
                      _measures(item),
                      const SizedBox(height: 16),
                      ..._buttons(item),
                      const SizedBox(height: 16),
                      Text('wp_history'.tr,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      for (final e in item.events)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                  '${e.at == null ? '' : DateFormat('dd.MM HH:mm').format(e.at!)}'
                                  ' · ${e.actor?.short ?? ''} '
                                  '${'wp_ev_${e.action}'.tr}',
                                  style: TextStyle(
                                      fontSize: 12, color: context.mutedColor)),
                              if (e.comment.isNotEmpty)
                                Text(e.comment,
                                    style: const TextStyle(fontSize: 14)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }

  Widget _banner(String text, Color color, {Key? key}) {
    return Container(
      key: key,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.readable(color).withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(text, style: TextStyle(color: context.readable(color))),
    );
  }

  BoxDecoration get _card => BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: context.cardShadow,
      );

  Widget _header(WorkPermit item) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(item.place,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              WorkPermitChip(status: item.status),
            ],
          ),
          const SizedBox(height: 4),
          Text(
              [
                'wp_kind_${item.kind}'.tr,
                workPermitSpan(item),
              ].where((s) => s.isNotEmpty).join(' · '),
              key: const Key('wp_span'),
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          const SizedBox(height: 8),
          SelectableText(item.work, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  Widget _people(WorkPermit item) {
    Widget row(String label, ItPerson? person) => person == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 150,
                  child: Text(label,
                      style:
                          TextStyle(fontSize: 12, color: context.mutedColor)),
                ),
                Expanded(child: Text(person.name)),
              ],
            ),
          );
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row('wp_issuer'.tr, item.issuer),
          row('wp_responsible'.tr, item.responsible),
          row('wp_performer'.tr, item.performer),
          row('wp_admitter'.tr, item.admitter),
          row('wp_approver'.tr, item.approver),
          if (item.members.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('wp_members'.tr,
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
            for (final m in item.members) Text('• $m'),
          ],
        ],
      ),
    );
  }

  Widget _measures(WorkPermit item) {
    if (item.measures.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('wp_measures'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          for (final m in item.measures)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined,
                      size: 16, color: context.mutedColor),
                  const SizedBox(width: 6),
                  Expanded(child: Text(m)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buttons(WorkPermit item) {
    Widget button(String action, IconData icon, {bool primary = false}) {
      final onPressed = _busy ? null : () => _act(action);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: primary
            ? SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                    key: Key('wp_$action'),
                    onPressed: onPressed,
                    icon: Icon(icon),
                    label: Text('wp_$action'.tr)))
            : OutlinedButton.icon(
                key: Key('wp_$action'),
                onPressed: onPressed,
                icon: Icon(icon),
                label: Text('wp_$action'.tr)),
      );
    }

    return [
      if (item.canApprove) ...[
        button('approve', Icons.verified_outlined, primary: true),
        button('reject', Icons.undo),
      ],
      if (item.canAdmit && !item.expired)
        button('admit', Icons.play_arrow, primary: true),
      if (item.canClose) button('close', Icons.check, primary: true),
      if (item.canStop) button('stop', Icons.pan_tool_outlined),
      if (item.canCancel) button('cancel', Icons.cancel_outlined),
      if (item.canComment) button('comment', Icons.chat_bubble_outline),
    ];
  }
}
