import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/it_request.dart';
import '../utils/api.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../utils/open_external.dart';
import '../utils/secure_storage_helper.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'it_requests_screen.dart';

/// Одна заявка: что сломалось, где, фото, кто делает и история.
///
/// Кнопки — по тому, кто смотрит: ОИТиС берёт и закрывает, автор отменяет
/// или говорит «не помогло». Писать сообщения могут оба.
class ItRequestDetailScreen extends StatefulWidget {
  const ItRequestDetailScreen(
      {Key? key, required this.requestId, this.staff = false})
      : super(key: key);

  final int requestId;

  /// Смотрит сотрудник ОИТиС: ему видны «Взять» и «Выполнено».
  final bool staff;

  @override
  State<ItRequestDetailScreen> createState() => _ItRequestDetailScreenState();
}

class _ItRequestDetailScreenState extends State<ItRequestDetailScreen> {
  ItRequest? _item;
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  Map<String, String> _headers = const {};
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
      final headers = await authHeaders();
      final me = await SecureStorageHelper.instance.getEmployeeId() ??
          await employeeIdFromServer();
      final item = await fetchItRequest(widget.requestId);
      if (!mounted) return;
      setState(() {
        _headers = headers;
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

  /// Чужую заявку сервер показывает только ОИТиС (и админу), так что
  /// смотрящий не автор — значит, из ОИТиС. Так экран знает это и тогда,
  /// когда открыт из оповещения, а не из очереди.
  bool get _staff =>
      widget.staff || (_item != null && _me != null && !_isAuthor);

  bool get _isAuthor => _item?.author?.id != null && _item?.author?.id == _me;

  Future<void> _act(String action, {String comment = ''}) async {
    setState(() => _busy = true);
    final result =
        await itRequestAction(widget.requestId, action, comment: comment);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.ok) _item = result.item;
    });
    if (result.ok) {
      if (action == 'comment') _comment.clear();
      return;
    }
    final key = 'it_err_${result.error}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.error != null && key.tr != key
            ? key.tr
            : 'it_err_failed'.tr)));
  }

  /// Спросить текст к действию: причину отказа, что сделано, что не помогло.
  Future<void> _actWithText(String action, String hint,
      {bool required = false}) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('it_$action'.tr),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          maxLength: 1000,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr)),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => TextButton(
              onPressed: required && value.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text('it_$action'.tr),
            ),
          ),
        ],
      ),
    );
    final text = controller.text.trim();
    controller.dispose();
    if (confirmed == true) await _act(action, comment: text);
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
              child: Text('it_cancel'.tr)),
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
            content: 'it_number'.trParams({'id': '${widget.requestId}'}),
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
                      if (item.photos.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _photos(item),
                      ],
                      const SizedBox(height: 20),
                      Text('it_history'.tr,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      for (final event in item.events) _event(event),
                      if (item.isOpen || _isAuthor || _staff) ...[
                        const SizedBox(height: 8),
                        _commentBox(),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _header(ItRequest item) {
    final created = item.createdAt == null
        ? ''
        : DateFormat('dd.MM.yyyy HH:mm').format(item.createdAt!);
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
              Icon(itCategoryIcon(item.category), color: context.mutedColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${'it_cat_${item.category}'.tr} · ${'it_room'.tr} ${item.room}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              ItStatusChip(status: item.status),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(item.description,
              style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 10),
          Text(created,
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          if (_staff && item.author != null) ...[
            const SizedBox(height: 4),
            Text(
              '${'it_author'.tr}: ${item.author!.name}'
              '${item.author!.department.isEmpty ? '' : ', ${item.author!.department}'}',
              style: TextStyle(fontSize: 12, color: context.mutedColor),
            ),
          ],
          if (item.phone.isNotEmpty) ...[
            const SizedBox(height: 4),
            InkWell(
              onTap: () => openExternal(context,
                  'tel:${item.phone.replaceAll(RegExp(r'[^0-9+]'), '')}'),
              child: Text('☎ ${item.phone}',
                  style: TextStyle(fontSize: 13, color: context.accentColor)),
            ),
          ],
          if (item.assignee != null) ...[
            const SizedBox(height: 4),
            Text('it_assignee'.trParams({'name': item.assignee!.name}),
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
          ],
          if (item.resolution.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(item.resolution,
                style: TextStyle(
                    fontSize: 13,
                    color: context.readable(itStatusColor(item.status)))),
          ],
        ],
      ),
    );
  }

  Widget _actions(ItRequest item) {
    final buttons = <Widget>[
      if (_staff && item.isOpen && item.assignee?.id != _me)
        ElevatedButton.icon(
          onPressed: _busy ? null : () => _act('take'),
          icon: const Icon(Icons.pan_tool_alt_outlined),
          label: Text('it_take'.tr),
        ),
      if (_staff && item.isOpen)
        ElevatedButton.icon(
          onPressed: _busy
              ? null
              : () => _actWithText('done', 'it_done_hint'.tr),
          icon: const Icon(Icons.check),
          label: Text('it_done'.tr),
        ),
      if (_staff && item.isOpen)
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () =>
                  _actWithText('reject', 'it_reject_hint'.tr, required: true),
          icon: const Icon(Icons.block),
          label: Text('it_reject'.tr),
        ),
      if (_isAuthor && item.isOpen)
        OutlinedButton.icon(
          onPressed: _busy ? null : _cancel,
          icon: const Icon(Icons.close),
          label: Text('it_cancel'.tr),
        ),
      if (_isAuthor && item.canReopen)
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _actWithText('reopen', 'it_reopen_hint'.tr),
          icon: const Icon(Icons.replay),
          label: Text('it_reopen'.tr),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _photos(ItRequest item) {
    return SizedBox(
      height: 120,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: item.photos.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final url = itPhotoUrl(item.id, item.photos[i]);
          return GestureDetector(
            onTap: () => _showPhoto(url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(url,
                  headers: _headers,
                  width: 120,
                  height: 120,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                        width: 120,
                        height: 120,
                        color: context.hairlineColor,
                        child: const Icon(Icons.broken_image_outlined),
                      )),
            ),
          );
        },
      ),
    );
  }

  void _showPhoto(String url) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(8),
        child: InteractiveViewer(
          child: Image.network(url, headers: _headers, fit: BoxFit.contain),
        ),
      ),
    );
  }

  Widget _event(ItEvent event) {
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
                  '${'it_ev_${event.action}'.tr}'
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
