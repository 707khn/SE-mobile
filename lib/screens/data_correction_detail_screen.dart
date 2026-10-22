import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/data_correction_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';
import 'data_corrections_screen.dart';

/// Просьба исправить данные: что было, как правильно, ответ кадров.
class DataCorrectionDetailScreen extends StatefulWidget {
  const DataCorrectionDetailScreen({Key? key, required this.correctionId})
      : super(key: key);

  final int correctionId;

  @override
  State<DataCorrectionDetailScreen> createState() =>
      _DataCorrectionDetailScreenState();
}

class _DataCorrectionDetailScreenState
    extends State<DataCorrectionDetailScreen> {
  DataCorrection? _item;
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
      final item = await fetchDataCorrection(widget.correctionId);
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
    if (action == 'done' || action == 'reject' || action == 'comment') {
      final label = action == 'comment' ? 'dc_comment_action' : 'dc_$action';
      final entered = await showDialog<String>(
        context: context,
        builder: (_) => TextPromptDialog(
            title: label.tr,
            hint: 'dc_${action}_hint'.tr,
            required: action != 'done'),
      );
      if (entered == null || !mounted) return;
      text = entered;
    }
    setState(() => _busy = true);
    final result =
        await dataCorrectionAction(widget.correctionId, action, text: text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    if (result.ok) return;
    final code = result.error;
    final key = 'dc_err_$code';
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
            content: 'dc_number'.trParams({'id': '${widget.correctionId}'}),
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
                      if (item.resolution.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: context
                                .readable(dataCorrectionColor(item.status))
                                .withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('dc_resolution'.tr,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              SelectableText(item.resolution,
                                  key: const Key('dc_resolution')),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      ..._buttons(item),
                      const SizedBox(height: 16),
                      Text('dc_history'.tr,
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
                                  '${'dc_ev_${e.action}'.tr}',
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

  Widget _header(DataCorrection item) {
    Widget field(String label, String value, {Key? key}) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 12, color: context.mutedColor)),
              SelectableText(value,
                  key: key, style: const TextStyle(fontSize: 15)),
            ],
          ),
        );
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
                child: Text('dc_kind_${item.kind}'.tr,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              DataCorrectionChip(status: item.status),
            ],
          ),
          if (item.author != null && !item.isAuthor)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                  '${item.author!.name}'
                  '${item.author!.department.isEmpty ? '' : ', ${item.author!.department}'}',
                  style: TextStyle(fontSize: 12, color: context.mutedColor)),
            ),
          if (item.current.isNotEmpty) field('dc_current'.tr, item.current),
          field('dc_requested'.tr, item.requested,
              key: const Key('dc_requested_value')),
          if (item.comment.isNotEmpty) field('dc_comment'.tr, item.comment),
        ],
      ),
    );
  }

  List<Widget> _buttons(DataCorrection item) {
    if (!item.isOpen) return const [];
    Widget button(String action, IconData icon, {bool primary = false}) {
      final onPressed = _busy ? null : () => _act(action);
      final label =
          (action == 'comment' ? 'dc_comment_action' : 'dc_$action').tr;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: primary
            ? SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                    key: Key('dc_$action'),
                    onPressed: onPressed,
                    icon: Icon(icon),
                    label: Text(label)))
            : OutlinedButton.icon(
                key: Key('dc_$action'),
                onPressed: onPressed,
                icon: Icon(icon),
                label: Text(label)),
      );
    }

    return [
      if (item.canHandle && item.status == 'new')
        button('take', Icons.play_arrow),
      if (item.canHandle) ...[
        button('done', Icons.check, primary: true),
        button('reject', Icons.block),
      ],
      if (item.isAuthor && item.status == 'new') button('cancel', Icons.undo),
      button('comment', Icons.chat_bubble_outline),
    ];
  }
}
