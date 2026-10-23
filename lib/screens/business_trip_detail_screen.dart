import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/business_trip_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';
import 'business_trips_screen.dart';

/// Командировка: заявка, аванс, авансовый отчёт и остаток.
class BusinessTripDetailScreen extends StatefulWidget {
  const BusinessTripDetailScreen(
      {Key? key, required this.tripId, this.dailyAllowance = 0})
      : super(key: key);

  final int tripId;

  /// Суточные за день — подсказка к строке суточных.
  final int dailyAllowance;

  @override
  State<BusinessTripDetailScreen> createState() =>
      _BusinessTripDetailScreenState();
}

class _BusinessTripDetailScreenState extends State<BusinessTripDetailScreen> {
  BusinessTrip? _item;
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
      final item = await fetchBusinessTrip(widget.tripId);
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

  Future<void> _send(String action,
      [Map<String, Object?> fields = const {}]) async {
    setState(() => _busy = true);
    final result = await businessTripAction(widget.tripId, action, fields);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    if (result.ok) return;
    final key = 'bt_err_${result.error}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.error != null && key.tr != key
            ? key.tr
            : 'it_err_failed'.tr)));
  }

  Future<void> _prompt(String action, {bool required = true}) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => TextPromptDialog(
          title: 'bt_$action'.tr,
          hint: 'bt_${action}_hint'.tr,
          required: required),
    );
    if (text == null || !mounted) return;
    await _send(action, {'text': text});
  }

  Future<void> _advance() async {
    final item = _item!;
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'bt_advance_action'.tr,
        okLabel: 'bt_advance_action'.tr,
        fields: [
          DialogField('amount', 'bt_advance_hint'.tr,
              number: true,
              required: true,
              initial:
                  item.advanceRequested > 0 ? '${item.advanceRequested}' : ''),
        ],
      ),
    );
    if (fields == null || !mounted) return;
    await _send('advance', fields);
  }

  Future<void> _addExpense() async {
    final category = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('bt_expense_add'.tr),
        children: [
          for (final c in tripCategories)
            SimpleDialogOption(
              key: Key('bt_category_$c'),
              onPressed: () => Navigator.pop(context, c),
              child: Text('bt_category_$c'.tr),
            ),
        ],
      ),
    );
    if (category == null || !mounted) return;
    final days = _item?.days ?? 1;
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'bt_category_$category'.tr,
        okLabel: 'bt_expense_save'.tr,
        fields: [
          DialogField('amount', 'bt_expense_amount'.tr,
              number: true,
              required: true,
              initial: category == 'per_diem' && widget.dailyAllowance > 0
                  ? '${widget.dailyAllowance * days}'
                  : ''),
          DialogField('document', 'bt_expense_document'.tr),
        ],
      ),
    );
    if (fields == null || !mounted) return;
    await _send('expense_add', {'category': category, ...fields});
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: 'bt_number'.trParams({'id': '${widget.tripId}'}),
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
                      if (item.note.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          key: const Key('bt_note'),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: context
                                .readable(businessTripColor(item.status))
                                .withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('${'bt_note'.tr}: ${item.note}'),
                        ),
                      ],
                      if (const {'approved', 'advanced', 'reported', 'closed'}
                          .contains(item.status)) ...[
                        const SizedBox(height: 16),
                        _report(item),
                      ],
                      const SizedBox(height: 16),
                      ..._buttons(item),
                      const SizedBox(height: 16),
                      Text('bt_history'.tr,
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
                                  '${'bt_ev_${e.action}'.tr}',
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

  BoxDecoration get _card => BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: context.cardShadow,
      );

  Widget _header(BusinessTrip item) {
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
                child: Text(item.destination,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              BusinessTripChip(status: item.status),
            ],
          ),
          const SizedBox(height: 4),
          Text(
              [
                businessTripDates(item),
                'bt_days'.trParams({'n': '${item.days}'}),
                'bt_transport_${item.transport}'.tr,
              ].where((s) => s.isNotEmpty).join(' · '),
              style: muted),
          if (item.organization.isNotEmpty) Text(item.organization),
          const SizedBox(height: 8),
          SelectableText(item.purpose),
          if (item.employee != null && !item.isMine) ...[
            const SizedBox(height: 6),
            Text(
                '${item.employee!.name}'
                '${item.employee!.department.isEmpty ? '' : ', ${item.employee!.department}'}',
                style: muted),
          ],
          const SizedBox(height: 8),
          if (item.advanceRequested > 0)
            Text(
                '${'bt_advance_requested'.tr}: ${tenge(item.advanceRequested)}'),
          if (item.advanceIssued != null)
            Text('${'bt_advance_issued'.tr}: ${tenge(item.advanceIssued!)}',
                key: const Key('bt_advance_issued')),
        ],
      ),
    );
  }

  Widget _report(BusinessTrip item) {
    final balance = item.balance;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('bt_expenses'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          if (item.expenses.isEmpty)
            Text('bt_no_expenses'.tr,
                style: TextStyle(color: context.mutedColor)),
          for (final e in item.expenses)
            Row(
              children: [
                Expanded(
                  child: Text([
                    'bt_category_${e.category}'.tr,
                    if (e.document.isNotEmpty) e.document,
                  ].join(' · ')),
                ),
                Text(tenge(e.amount)),
                if (item.canEditReport)
                  IconButton(
                    key: Key('bt_expense_remove_${e.id}'),
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: _busy
                        ? null
                        : () => _send('expense_remove', {'expense_id': e.id}),
                  ),
              ],
            ),
          const Divider(),
          Text('bt_spent'.trParams({'sum': tenge(item.spent)}),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
              balance > 0
                  ? 'bt_to_return'.trParams({'sum': tenge(balance)})
                  : balance < 0
                      ? 'bt_to_pay'.trParams({'sum': tenge(-balance)})
                      : 'bt_even'.tr,
              key: const Key('bt_balance')),
          if (item.canEditReport) ...[
            const SizedBox(height: 4),
            Text('bt_paper_note'.tr,
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
          ],
        ],
      ),
    );
  }

  List<Widget> _buttons(BusinessTrip item) {
    Widget button(String key, IconData icon, VoidCallback onPressed,
        {bool primary = false}) {
      final action = _busy ? null : onPressed;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: primary
            ? SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                    key: Key('bt_$key'),
                    onPressed: action,
                    icon: Icon(icon),
                    label: Text('bt_$key'.tr)))
            : OutlinedButton.icon(
                key: Key('bt_$key'),
                onPressed: action,
                icon: Icon(icon),
                label: Text('bt_$key'.tr)),
      );
    }

    return [
      if (item.canApprove) ...[
        button('approve', Icons.check, () => _send('approve'), primary: true),
        button('reject', Icons.block, () => _prompt('reject')),
      ],
      if (item.canAdvance)
        button('advance_action', Icons.payments_outlined, _advance,
            primary: true),
      if (item.canEditReport) ...[
        button('expense_add', Icons.add, _addExpense),
        button('report', Icons.send, () => _send('report'), primary: true),
      ],
      if (item.canCheck) ...[
        button('accept', Icons.check, () => _send('accept'), primary: true),
        button('send_back', Icons.undo, () => _prompt('send_back')),
      ],
      if (item.canCancel)
        button('cancel', Icons.cancel_outlined, () => _send('cancel')),
      if (item.isOpen)
        button('comment', Icons.chat_bubble_outline, () => _prompt('comment')),
    ];
  }
}
