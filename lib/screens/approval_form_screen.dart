import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../requests/approval_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';

/// Новый лист согласования: что за документ и по какому маршруту идёт.
class ApprovalFormScreen extends StatefulWidget {
  const ApprovalFormScreen({Key? key}) : super(key: key);

  @override
  State<ApprovalFormScreen> createState() => _ApprovalFormScreenState();
}

const _maxSteps = 8;

class _ApprovalFormScreenState extends State<ApprovalFormScreen> {
  final _title = TextEditingController();
  final _number = TextEditingController();
  final _counterparty = TextEditingController();
  final _amount = TextEditingController();
  final _summary = TextEditingController();
  String _kind = 'contract';
  List<ApprovalPerson> _route = [];

  /// Маршрут ещё тот, что предложило приложение: при смене вида документа
  /// его можно заменить, не спрашивая. Тронутый руками — не трогаем.
  bool _routeSuggested = true;
  bool _loadingRoute = false;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _suggest();
  }

  @override
  void dispose() {
    _title.dispose();
    _number.dispose();
    _counterparty.dispose();
    _amount.dispose();
    _summary.dispose();
    super.dispose();
  }

  Future<void> _suggest() async {
    final kind = _kind;
    setState(() => _loadingRoute = true);
    List<ApprovalPerson> route;
    try {
      route = await fetchSuggestedRoute(kind);
    } catch (_) {
      route = const [];
    }
    if (!mounted) return;
    setState(() {
      _loadingRoute = false;
      if (kind != _kind) return;
      _route = route.take(_maxSteps).toList();
      _routeSuggested = true;
    });
  }

  void _setKind(String kind) {
    setState(() => _kind = kind);
    if (_routeSuggested || _route.isEmpty) _suggest();
  }

  void _editRoute(void Function() change) {
    setState(() {
      change();
      _routeSuggested = false;
    });
  }

  Future<void> _addApprover() async {
    final picked = await showDialog<ApprovalPerson>(
      context: context,
      builder: (_) => const _ApproverPicker(),
    );
    if (picked == null || _route.contains(picked)) return;
    _editRoute(() => _route.add(picked));
  }

  String _errorText(String? code) {
    for (final key in ['appr_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _send() async {
    final title = _title.text.trim();
    final summary = _summary.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'appr_err_title_required'.tr);
      return;
    }
    if (summary.isEmpty) {
      setState(() => _error = 'appr_err_summary_required'.tr);
      return;
    }
    if (_route.isEmpty) {
      setState(() => _error = 'appr_err_route_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await createApproval(
      kind: _kind,
      title: title,
      summary: summary,
      route: [for (final p in _route) p.id],
      docNumber: _number.text.trim(),
      counterparty: _counterparty.text.trim(),
      amount: _amount.text.trim(),
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(result.item);
      return;
    }
    setState(() {
      _sending = false;
      _error = _errorText(result.error);
    });
  }

  InputDecoration _field(String label, {String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        counterText: '',
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'appr_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final kind in approvalKinds)
                ChoiceChip(
                  key: Key('appr_kind_$kind'),
                  label: Text('appr_kind_$kind'.tr),
                  selected: _kind == kind,
                  onSelected: _sending ? null : (_) => _setKind(kind),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('appr_title'),
            controller: _title,
            maxLength: 200,
            decoration:
                _field('appr_doc_title'.tr, hint: 'appr_doc_title_hint'.tr),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('appr_number'),
            controller: _number,
            maxLength: 100,
            decoration: _field('appr_doc_number'.tr),
          ),
          if (_kind == 'contract') ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('appr_counterparty'),
              controller: _counterparty,
              maxLength: 200,
              decoration: _field('appr_counterparty'.tr),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('appr_amount'),
              controller: _amount,
              maxLength: 50,
              decoration: _field('appr_amount'.tr),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            key: const Key('appr_summary'),
            controller: _summary,
            maxLength: 4000,
            minLines: 3,
            maxLines: 8,
            decoration:
                _field('appr_summary'.tr, hint: 'appr_summary_hint'.tr),
          ),
          const SizedBox(height: 6),
          Text('appr_no_files'.tr,
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text('appr_route'.tr,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
              if (_loadingRoute)
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else if (_kind != 'other')
                TextButton(
                  key: const Key('appr_suggest'),
                  onPressed: _sending ? null : _suggest,
                  child: Text('appr_route_suggest'.tr),
                ),
            ],
          ),
          if (_route.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('appr_route_empty'.tr,
                  style: TextStyle(color: context.mutedColor)),
            ),
          for (var i = 0; i < _route.length; i++) _routeRow(i),
          if (_route.length < _maxSteps)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('appr_add_step'),
                onPressed: _sending ? null : _addApprover,
                icon: const Icon(Icons.person_add_alt),
                label: Text('appr_route_add'.tr),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('appr_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('appr_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('appr_new'.tr),
            ),
          ),
        ],
      ),
    );
  }

  Widget _routeRow(int index) {
    final person = _route[index];
    return Padding(
      key: Key('appr_step_${person.id}'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: context.accentColor.withOpacity(0.12),
            child: Text('${index + 1}',
                style: TextStyle(fontSize: 12, color: context.accentColor)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(person.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                if (person.title.isNotEmpty)
                  Text(person.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12, color: context.mutedColor)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed: _sending || index == 0
                ? null
                : () => _editRoute(() =>
                    _route.insert(index - 1, _route.removeAt(index))),
          ),
          IconButton(
            key: Key('appr_remove_${person.id}'),
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            onPressed:
                _sending ? null : () => _editRoute(() => _route.removeAt(index)),
          ),
        ],
      ),
    );
  }
}

/// Поиск согласующего: печатаешь фамилию или «главный бухгалтер».
class _ApproverPicker extends StatefulWidget {
  const _ApproverPicker();

  @override
  State<_ApproverPicker> createState() => _ApproverPickerState();
}

class _ApproverPickerState extends State<_ApproverPicker> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<ApprovalPerson> _found = const [];
  bool _searching = false;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(text));
  }

  Future<void> _search(String text) async {
    final seq = ++_seq;
    if (text.trim().length < 2) {
      setState(() => _found = const []);
      return;
    }
    setState(() => _searching = true);
    List<ApprovalPerson> found;
    try {
      found = await searchApprovers(text.trim());
    } catch (_) {
      found = const [];
    }
    // Ответ на старый запрос пришёл позже нового — не показываем.
    if (!mounted || seq != _seq) return;
    setState(() {
      _found = found;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('appr_route_add'.tr),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              key: const Key('appr_search'),
              controller: _query,
              autofocus: true,
              onChanged: _changed,
              decoration: InputDecoration(
                hintText: 'appr_route_search'.tr,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                child: ListView(
                  children: [
                    for (final p in _found)
                      ListTile(
                        key: Key('appr_found_${p.id}'),
                        dense: true,
                        title: Text(p.name),
                        subtitle: Text(
                            [p.title, p.department]
                                .where((s) => s.isNotEmpty)
                                .join(', '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(context, p),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
      ],
    );
  }
}
