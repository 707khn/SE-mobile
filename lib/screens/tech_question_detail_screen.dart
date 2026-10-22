import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/tech_question_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';
import 'tech_questions_screen.dart';

/// Вопрос в ТО: суть, решение и переписка; кнопки — по роли.
class TechQuestionDetailScreen extends StatefulWidget {
  const TechQuestionDetailScreen({Key? key, required this.questionId})
      : super(key: key);

  final int questionId;

  @override
  State<TechQuestionDetailScreen> createState() =>
      _TechQuestionDetailScreenState();
}

class _TechQuestionDetailScreenState extends State<TechQuestionDetailScreen> {
  TechQuestion? _item;
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
      final item = await fetchTechQuestion(widget.questionId);
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

  Future<void> _act(String action) async {
    var text = '';
    if (action == 'answer' || action == 'clarify' || action == 'comment') {
      final entered = await showDialog<String>(
        context: context,
        builder: (_) => TextPromptDialog(
            title: 'tq_$action'.tr,
            hint: 'tq_${action}_hint'.tr,
            required: true),
      );
      if (entered == null || !mounted) return;
      text = entered;
    }
    setState(() => _busy = true);
    final result =
        await techQuestionAction(widget.questionId, action, text: text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    if (result.ok) return;
    final code = result.error;
    final key = 'tq_err_$code';
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
            content: 'tq_number'.trParams({'id': '${widget.questionId}'}),
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
                      if (item.decision.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: context
                                .readable(const Color(0xFF2E7D32))
                                .withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('tq_decision'.tr,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              SelectableText(item.decision,
                                  key: const Key('tq_decision')),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      ..._buttons(item),
                      const SizedBox(height: 16),
                      Text('tq_history'.tr,
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
                                  '${'tq_ev_${e.action}'.tr}',
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

  Widget _header(TechQuestion item) {
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
                child: Text(item.product,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              TechQuestionChip(status: item.status),
            ],
          ),
          const SizedBox(height: 4),
          Text(
              [
                'tq_kind_${item.kind}'.tr,
                if (item.where.isNotEmpty) item.where,
                if (item.urgent) 'tq_urgent'.tr,
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          const SizedBox(height: 8),
          SelectableText(item.text, style: const TextStyle(fontSize: 14)),
          if (item.author != null && !item.isAuthor) ...[
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

  List<Widget> _buttons(TechQuestion item) {
    if (item.status == 'closed') return const [];
    Widget button(String action, IconData icon, {bool primary = false}) {
      final onPressed = _busy ? null : () => _act(action);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: primary
            ? SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                    key: Key('tq_$action'),
                    onPressed: onPressed,
                    icon: Icon(icon),
                    label: Text('tq_$action'.tr)))
            : OutlinedButton.icon(
                key: Key('tq_$action'),
                onPressed: onPressed,
                icon: Icon(icon),
                label: Text('tq_$action'.tr)),
      );
    }

    return [
      if (item.canAnswer && item.status == 'new')
        button('take', Icons.play_arrow),
      if (item.canAnswer)
        button('answer', Icons.lightbulb_outline, primary: true),
      if (item.isAuthor && item.status == 'answered') ...[
        button('close', Icons.check, primary: true),
        button('clarify', Icons.help_outline),
      ],
      if (item.canAnswer || item.isAuthor)
        button('comment', Icons.chat_bubble_outline),
    ];
  }
}
