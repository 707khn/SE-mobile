import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/it_request.dart' show ItPerson;
import '../requests/purchase_request.dart';
import '../utils/api.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../utils/secure_storage_helper.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';
import 'purchases_screen.dart';

/// Одна закупка: что и для чего, этапы с датами, ответственный и история.
///
/// Менеджер ДМТО берёт её, двигает этап (с поставщиком и датой поставки)
/// или отказывает; руководитель передаёт другому; инициатор отменяет.
class PurchaseDetailScreen extends StatefulWidget {
  const PurchaseDetailScreen({Key? key, required this.purchaseId})
      : super(key: key);

  final int purchaseId;

  @override
  State<PurchaseDetailScreen> createState() => _PurchaseDetailScreenState();
}

class _PurchaseDetailScreenState extends State<PurchaseDetailScreen> {
  Purchase? _item;
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
      final item = await fetchPurchase(widget.purchaseId);
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

  Future<void> _act(String action,
      {String comment = '',
      String? stage,
      String? assigneeId,
      String supplier = '',
      DateTime? eta}) async {
    setState(() => _busy = true);
    final result = await purchaseAction(widget.purchaseId, action,
        comment: comment,
        stage: stage,
        assigneeId: assigneeId,
        supplier: supplier,
        eta: eta);
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
    for (final key in ['purch_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _reject() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
          title: 'purch_reject'.tr,
          hint: 'purch_reject_hint'.tr,
          required: true),
    );
    if (text != null) await _act('reject', comment: text);
  }

  Future<void> _nextStage(Purchase item) async {
    final choice = await showDialog<_StageChoice>(
      context: context,
      builder: (_) => _StageDialog(item: item),
    );
    if (choice == null) return;
    await _act('stage',
        stage: choice.stage,
        supplier: choice.supplier,
        eta: choice.eta,
        comment: choice.comment);
  }

  Future<void> _assign() async {
    List<ItPerson> staff;
    try {
      staff = await fetchPurchaseStaff();
    } catch (_) {
      staff = const [];
    }
    if (!mounted || staff.isEmpty) return;
    final picked = await showDialog<ItPerson>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('purch_assign'.tr),
        children: [
          for (final p in staff)
            SimpleDialogOption(
              key: Key('purch_staff_${p.id}'),
              onPressed: () => Navigator.pop(context, p),
              child: Text(p.name),
            ),
        ],
      ),
    );
    if (picked != null) await _act('assign', assigneeId: picked.id);
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
              child: Text('purch_cancel'.tr)),
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
            content: 'purch_number'.trParams({'id': '${widget.purchaseId}'}),
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
                      if (item.stageIndex >= 0) ...[
                        const SizedBox(height: 16),
                        for (final stage in purchaseStages) _stage(item, stage),
                      ],
                      const SizedBox(height: 16),
                      Text('purch_lines'.tr,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      for (final line in item.lines)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Expanded(
                                  child: Text(line.name,
                                      style: const TextStyle(fontSize: 14))),
                              Text(line.amount,
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

  Widget _header(Purchase item) {
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
                child: Text(item.purpose,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              PurchaseStageChip(status: item.status),
            ],
          ),
          const SizedBox(height: 8),
          Text(
              [
                if (item.urgent) 'purch_urgent'.tr,
                if (item.neededBy != null)
                  'purch_needed_by_date'.trParams(
                      {'date': DateFormat('dd.MM.yyyy').format(item.neededBy!)}),
                if (item.stale) 'purch_stale'.tr,
              ].join(' · '),
              style: muted),
          if (!item.isAuthor && item.author != null) ...[
            const SizedBox(height: 4),
            Text(
                '${'it_author'.tr}: ${item.author!.name}'
                '${item.author!.department.isEmpty ? '' : ', ${item.author!.department}'}',
                style: muted),
          ],
          if (item.assignee != null) ...[
            const SizedBox(height: 4),
            Text('purch_assignee'.trParams({'name': item.assignee!.name}),
                key: const Key('purch_assignee'), style: muted),
          ],
          if (item.supplier.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('${'purch_supplier'.tr}: ${item.supplier}',
                style: const TextStyle(fontSize: 13)),
          ],
          if (item.eta != null && item.isOpen) ...[
            const SizedBox(height: 4),
            Text(
                'purch_eta'.trParams(
                    {'date': DateFormat('dd.MM.yyyy').format(item.eta!)}),
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.readable(purchaseStageColor('in_transit')))),
          ],
          if (item.reason.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('purch_reason'.trParams({'reason': item.reason}),
                style: TextStyle(
                    fontSize: 13,
                    color: context.readable(purchaseStageColor('rejected')))),
          ],
        ],
      ),
    );
  }

  Widget _stage(Purchase item, String stage) {
    final index = purchaseStages.indexOf(stage);
    final done = index <= item.stageIndex;
    final current = index == item.stageIndex;
    final at = item.reachedAt(stage);
    final color = done
        ? context.readable(purchaseStageColor(item.status))
        : context.mutedColor;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text('purch_stage_$stage'.tr,
                style: TextStyle(
                    fontSize: 14,
                    color: done ? null : context.mutedColor,
                    fontWeight: current ? FontWeight.w700 : null)),
          ),
          if (done && at != null)
            Text(DateFormat('dd.MM').format(at),
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
        ],
      ),
    );
  }

  Widget _actions(Purchase item) {
    final mine = item.assignee?.id != null && item.assignee?.id == _me;
    final buttons = <Widget>[
      if (item.canAct && !mine)
        ElevatedButton.icon(
          key: const Key('purch_take'),
          onPressed: _busy ? null : () => _act('take'),
          icon: const Icon(Icons.pan_tool_alt_outlined),
          label: Text('purch_take'.tr),
        ),
      if (item.canAct && item.nextStages.isNotEmpty)
        ElevatedButton.icon(
          key: const Key('purch_next'),
          onPressed: _busy ? null : () => _nextStage(item),
          icon: const Icon(Icons.arrow_forward),
          label: Text('purch_next'.tr),
        ),
      if (item.canAssign)
        OutlinedButton.icon(
          key: const Key('purch_assign'),
          onPressed: _busy ? null : _assign,
          icon: const Icon(Icons.swap_horiz),
          label: Text('purch_assign'.tr),
        ),
      if (item.canAct)
        OutlinedButton.icon(
          key: const Key('purch_reject'),
          onPressed: _busy ? null : _reject,
          icon: const Icon(Icons.block),
          label: Text('purch_reject'.tr),
        ),
      if (item.isAuthor && item.isOpen)
        OutlinedButton.icon(
          key: const Key('purch_cancel'),
          onPressed: _busy ? null : _cancel,
          icon: const Icon(Icons.close),
          label: Text('purch_cancel'.tr),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _event(PurchaseEvent event) {
    final when =
        event.at == null ? '' : DateFormat('dd.MM HH:mm').format(event.at!);
    final label = event.action == 'stage' && event.stage.isNotEmpty
        ? 'purch_stage_${event.stage}'.tr
        : 'purch_ev_${event.action}'.tr;
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
                  '$label'
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

class _StageChoice {
  const _StageChoice(
      {required this.stage, this.supplier = '', this.eta, this.comment = ''});

  final String stage;
  final String supplier;
  final DateTime? eta;
  final String comment;
}

/// Куда перевести: этап, поставщик, дата поставки и пара слов инициатору.
class _StageDialog extends StatefulWidget {
  const _StageDialog({required this.item});

  final Purchase item;

  @override
  State<_StageDialog> createState() => _StageDialogState();
}

class _StageDialogState extends State<_StageDialog> {
  late String _stage = widget.item.nextStages.first;
  late final _supplier = TextEditingController(text: widget.item.supplier);
  final _comment = TextEditingController();
  late DateTime? _eta = widget.item.eta;

  @override
  void dispose() {
    _supplier.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _pickEta() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _eta ?? today.add(const Duration(days: 7)),
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (picked != null && mounted) setState(() => _eta = picked);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('purch_next_title'.tr),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final stage in widget.item.nextStages)
                  ChoiceChip(
                    key: Key('purch_to_$stage'),
                    label: Text('purch_stage_$stage'.tr),
                    selected: _stage == stage,
                    onSelected: (_) => setState(() => _stage = stage),
                  ),
              ],
            ),
            if (_stage != 'delivered') ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('purch_supplier'),
                controller: _supplier,
                maxLength: 200,
                decoration: InputDecoration(
                  labelText: 'purch_supplier'.tr,
                  hintText: 'purch_supplier_hint'.tr,
                  counterText: '',
                ),
              ),
            ],
            if (_stage == 'in_transit') ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('purch_eta'),
                onPressed: _pickEta,
                icon: const Icon(Icons.event),
                label: Text(_eta == null
                    ? 'purch_eta_pick'.tr
                    : DateFormat('dd.MM.yyyy').format(_eta!)),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              key: const Key('purch_stage_comment'),
              controller: _comment,
              maxLength: 1000,
              maxLines: 2,
              decoration: InputDecoration(
                  hintText: 'purch_comment_hint'.tr, counterText: ''),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
        TextButton(
          key: const Key('purch_stage_ok'),
          onPressed: () => Navigator.pop(
              context,
              _StageChoice(
                stage: _stage,
                supplier:
                    _stage == 'delivered' ? '' : _supplier.text.trim(),
                eta: _stage == 'in_transit' ? _eta : null,
                comment: _comment.text.trim(),
              )),
          child: Text('purch_next'.tr),
        ),
      ],
    );
  }
}
