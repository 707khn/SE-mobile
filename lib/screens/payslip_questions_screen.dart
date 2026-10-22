import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/payslip_question_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/lang.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'payslip_question_detail_screen.dart';

Color payslipQuestionColor(String status) => switch (status) {
      'open' => const Color(0xFF1565C0),
      'answered' => const Color(0xFF2E7D32),
      _ => const Color(0xFF757575),
    };

/// «Сентябрь 2026» — как в заголовке листка.
String payslipPeriodTitle(DateTime month) {
  final text = DateFormat('LLLL yyyy', Lang.dates).format(month);
  return text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}

class PayslipQuestionChip extends StatelessWidget {
  const PayslipQuestionChip({Key? key, required this.status})
      : super(key: key);

  final String status;

  @override
  Widget build(BuildContext context) {
    final color = context.readable(payslipQuestionColor(status));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text('psq_status_$status'.tr,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Вопросы по листку: свои, а у расчётной группы — очередь.
class PayslipQuestionsScreen extends StatefulWidget {
  const PayslipQuestionsScreen({Key? key}) : super(key: key);

  @override
  State<PayslipQuestionsScreen> createState() => _PayslipQuestionsScreenState();
}

class _PayslipQuestionsScreenState extends State<PayslipQuestionsScreen> {
  bool _loading = true;
  bool _failed = false;
  LoadProblem? _problem;
  PayslipQuestionList _mine = const PayslipQuestionList(items: []);
  PayslipQuestionList? _queue;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final mine = await fetchPayslipQuestions();
      final queue =
          mine.staff ? await fetchPayslipQuestions(queue: true) : null;
      if (!mounted) return;
      setState(() {
        _mine = mine;
        _queue = queue;
        _failed = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _failed = true;
        _problem = problemOfAny(e);
        _loading = false;
      });
    }
  }

  Future<void> _open(PayslipQuestion item) async {
    await Get.to(() => PayslipQuestionDetailScreen(questionId: item.id));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final queue = _queue;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _failed
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : queue == null
                ? _list(_mine.items, 'psq_empty_mine'.tr)
                : TabBarView(children: [
                    _list(queue.items, 'psq_empty_queue'.tr, staff: true),
                    _list(_mine.items, 'psq_empty_mine'.tr),
                  ]);
    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'psq_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: queue == null
            ? null
            : TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: [
                  Tab(
                      text: queue.open > 0
                          ? '${'psq_queue'.tr} (${queue.open})'
                          : 'psq_queue'.tr),
                  Tab(text: 'psq_mine'.tr),
                ],
              ),
      ),
      body: body,
    );
    return queue == null
        ? scaffold
        : DefaultTabController(length: 2, child: scaffold);
  }

  Widget _list(List<PayslipQuestion> items, String empty,
      {bool staff = false}) {
    return RefreshIndicator(
      onRefresh: _load,
      child: items.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(32),
              children: [
                Icon(Icons.contact_support_outlined,
                    size: 56, color: context.mutedColor),
                const SizedBox(height: 12),
                Text(empty,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.mutedColor)),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(top: 8, bottom: 32),
              itemCount: items.length,
              itemBuilder: (_, i) => _row(items[i], staff),
            ),
    );
  }

  Widget _row(PayslipQuestion item, bool staff) {
    final when = item.updatedAt == null
        ? ''
        : DateFormat('dd.MM HH:mm').format(item.updatedAt!);
    final waiting = staff ? item.status == 'open' : item.status == 'answered';
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: context.cardShadow,
        border: waiting
            ? Border(
                left: BorderSide(
                    color: payslipQuestionColor(item.status), width: 3))
            : null,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _open(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                        '№${item.id} · ${payslipPeriodTitle(item.period)}',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                  PayslipQuestionChip(status: item.status),
                ],
              ),
              if (item.preview.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(item.preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ],
              const SizedBox(height: 4),
              Text(
                [
                  when,
                  if (staff && item.author != null) item.author!.short,
                  if (item.line.isNotEmpty) item.line,
                ].where((s) => s.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: context.mutedColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Задать вопрос по листку за месяц; строки — из самого листка.
class PayslipAskScreen extends StatefulWidget {
  const PayslipAskScreen(
      {Key? key, required this.month, this.lines = const []})
      : super(key: key);

  final DateTime month;

  /// «Начисления: Оклад — 250 000,00» — человек выбирает одну.
  final List<String> lines;

  @override
  State<PayslipAskScreen> createState() => _PayslipAskScreenState();
}

class _PayslipAskScreenState extends State<PayslipAskScreen> {
  final _text = TextEditingController();
  String? _line;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String _errorText(String? code) {
    for (final key in ['psq_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'psq_err_text_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await askPayslipQuestion(
        year: widget.month.year,
        month: widget.month.month,
        text: text,
        line: _line ?? '');
    if (!mounted) return;
    if (result.ok) {
      Get.off(() => PayslipQuestionDetailScreen(questionId: result.item!.id));
      return;
    }
    setState(() {
      _sending = false;
      _error = _errorText(result.error);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'psq_ask'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
              'psq_period'
                  .trParams({'period': payslipPeriodTitle(widget.month)}),
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('psq_ask_hint'.tr,
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          if (widget.lines.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('psq_line'.tr,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String?>(
              key: const Key('psq_line'),
              initialValue: _line,
              isExpanded: true,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), isDense: true),
              items: [
                DropdownMenuItem<String?>(
                    value: null, child: Text('psq_line_none'.tr)),
                for (final line in widget.lines)
                  DropdownMenuItem<String?>(
                      value: line,
                      child: Text(line, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (value) => setState(() => _line = value),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            key: const Key('psq_text'),
            controller: _text,
            maxLength: 2000,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: 'psq_text'.tr,
              hintText: 'psq_text_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('psq_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('psq_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('it_send'.tr),
            ),
          ),
        ],
      ),
    );
  }
}
