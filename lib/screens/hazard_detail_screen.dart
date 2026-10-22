import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/hazard_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import '../widgets/text_prompt_dialog.dart';
import 'hazards_screen.dart';

/// Одно сообщение: что, где, что сделала БиОТ; кнопки — инженеру БиОТ.
class HazardDetailScreen extends StatefulWidget {
  const HazardDetailScreen(
      {Key? key, required this.hazardId, this.anonymous = false})
      : super(key: key);

  final int hazardId;

  /// Своё анонимное: сервер не знает, что оно моё, поэтому читаем его по
  /// ключам, сохранённым на телефоне.
  final bool anonymous;

  @override
  State<HazardDetailScreen> createState() => _HazardDetailScreenState();
}

class _HazardDetailScreenState extends State<HazardDetailScreen> {
  Hazard? _item;
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
      final Hazard item;
      if (widget.anonymous) {
        final tracked = await trackHazards(await savedHazardTracks());
        final found = tracked.where((h) => h.id == widget.hazardId);
        if (found.isEmpty) throw const LoadFailure(LoadProblem.server);
        item = found.first;
      } else {
        item = await fetchHazard(widget.hazardId);
      }
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
    var comment = '';
    if (action != 'take') {
      final text = await showDialog<String>(
        context: context,
        builder: (_) => TextPromptDialog(
            title: 'hz_$action'.tr,
            hint: 'hz_${action}_hint'.tr,
            required: true),
      );
      if (text == null || !mounted) return;
      comment = text;
    }
    setState(() => _busy = true);
    final result =
        await hazardAction(widget.hazardId, action, comment: comment);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    if (result.ok) return;
    final code = result.error;
    final key = 'hz_err_$code';
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
            content: 'hz_number'.trParams({'id': '${widget.hazardId}'}),
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
                      if (item.outcome.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: context
                                .readable(hazardStatusColor(item.status))
                                .withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: SelectableText(
                              'hz_outcome'.trParams({'text': item.outcome}),
                              key: const Key('hz_outcome')),
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (item.canAct) ...[
                        if (item.status == 'new')
                          _button('take', Icons.play_arrow, primary: true),
                        _button('resolve', Icons.check, primary: true),
                        _button('reject', Icons.block),
                      ],
                      if (item.canAct || (item.isAuthor && item.isOpen))
                        _button('comment', Icons.chat_bubble_outline),
                      const SizedBox(height: 16),
                      Text('hz_history'.tr,
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
                                  ' · ${e.actor?.short ?? 'hz_someone'.tr} '
                                  '${'hz_ev_${e.action}'.tr}',
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

  Widget _header(Hazard item) {
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
              Icon(hazardIcon(item.category)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('hz_cat_${item.category}'.tr,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              HazardStatusChip(status: item.status),
            ],
          ),
          if (item.urgent) ...[
            const SizedBox(height: 4),
            Text('hz_urgent'.tr,
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: context.readable(const Color(0xFFC62828)))),
          ],
          const SizedBox(height: 8),
          Text(item.place, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          SelectableText(item.text, style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 6),
          Text(
              item.anonymous
                  ? 'hz_anonymous_badge'.tr
                  : (item.author?.name ?? ''),
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
        ],
      ),
    );
  }

  Widget _button(String action, IconData icon, {bool primary = false}) {
    final onPressed = _busy ? null : () => _act(action);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: primary
          ? SizedBox(
              height: 48,
              child: ElevatedButton.icon(
                  key: Key('hz_$action'),
                  onPressed: onPressed,
                  icon: Icon(icon),
                  label: Text('hz_$action'.tr)),
            )
          : OutlinedButton.icon(
              key: Key('hz_$action'),
              onPressed: onPressed,
              icon: Icon(icon),
              label: Text('hz_$action'.tr)),
    );
  }
}
