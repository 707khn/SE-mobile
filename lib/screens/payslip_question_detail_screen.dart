import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/payslip_question_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'payslip_questions_screen.dart';

/// Переписка по одному вопросу: автор слева, расчётная группа справа — у
/// бухгалтера наоборот, своё всегда справа.
class PayslipQuestionDetailScreen extends StatefulWidget {
  const PayslipQuestionDetailScreen({Key? key, required this.questionId})
      : super(key: key);

  final int questionId;

  @override
  State<PayslipQuestionDetailScreen> createState() =>
      _PayslipQuestionDetailScreenState();
}

class _PayslipQuestionDetailScreenState
    extends State<PayslipQuestionDetailScreen> {
  PayslipQuestion? _item;
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  final _reply = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final item = await fetchPayslipQuestion(widget.questionId);
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

  Future<void> _act(String action, {String text = ''}) async {
    setState(() => _busy = true);
    final result =
        await payslipQuestionAction(widget.questionId, action, text: text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    if (result.ok) {
      if (action == 'reply') _reply.clear();
      return;
    }
    final code = result.error;
    final key = 'psq_err_$code';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            code != null && key.tr != key ? key.tr : 'it_err_failed'.tr)));
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content: 'psq_number'.trParams({'id': '${widget.questionId}'}),
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
              : Column(
                  children: [
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                          children: [
                            _header(item),
                            const SizedBox(height: 12),
                            for (final m in item.messages) _message(item, m),
                          ],
                        ),
                      ),
                    ),
                    if (item.isAuthor || item.canAnswer) _replyBar(item),
                  ],
                ),
    );
  }

  Widget _header(PayslipQuestion item) {
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
                    'psq_period'
                        .trParams({'period': payslipPeriodTitle(item.period)}),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              PayslipQuestionChip(status: item.status),
            ],
          ),
          if (item.line.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(item.line, style: const TextStyle(fontSize: 13)),
          ],
          if (!item.isAuthor && item.author != null) ...[
            const SizedBox(height: 6),
            Text(
                '${item.author!.name}'
                '${item.author!.department.isEmpty ? '' : ', ${item.author!.department}'}',
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
          ],
        ],
      ),
    );
  }

  Widget _message(PayslipQuestion item, PayslipQuestionMessage m) {
    final when = m.at == null ? '' : DateFormat('dd.MM HH:mm').format(m.at!);
    if (m.kind == 'closed') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('${'psq_closed_note'.tr} · $when',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: context.mutedColor)),
      );
    }
    // Своё — справа: у автора это его вопросы, у бухгалтера — ответы.
    final own = item.isAuthor ? !m.fromPayroll : m.fromPayroll;
    final who = m.fromPayroll
        ? '${'psq_payroll'.tr}${m.author == null ? '' : ' · ${m.author!.short}'}'
        : (item.isAuthor ? 'psq_you'.tr : (m.author?.short ?? ''));
    final color = own ? context.accentColor : context.mutedColor;
    return Align(
      alignment: own ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment:
              own ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text('$who · $when',
                style: TextStyle(fontSize: 11, color: context.mutedColor)),
            const SizedBox(height: 2),
            SelectableText(m.text, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _replyBar(PayslipQuestion item) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: context.cardSurface,
          border: Border(top: BorderSide(color: context.hairlineColor)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('psq_reply'),
                    controller: _reply,
                    maxLength: 2000,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: 'psq_reply_hint'.tr,
                      border: const OutlineInputBorder(),
                      isDense: true,
                      counterText: '',
                    ),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _reply,
                  builder: (context, value, _) => IconButton(
                    key: const Key('psq_reply_send'),
                    icon: const Icon(Icons.send),
                    tooltip: 'it_send'.tr,
                    onPressed: _busy || value.text.trim().isEmpty
                        ? null
                        : () => _act('reply', text: value.text.trim()),
                  ),
                ),
              ],
            ),
            if (item.isAuthor && item.status == 'answered')
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('psq_close'),
                  onPressed: _busy ? null : () => _act('close'),
                  icon: const Icon(Icons.check),
                  label: Text('psq_close'.tr),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
