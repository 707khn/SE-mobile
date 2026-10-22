import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/compliance_request.dart';
import '../utils/app_theme.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';

String _errorText(ComplianceResult result) {
  final key = 'cp_err_${result.error}';
  return result.error != null && key.tr != key ? key.tr : 'it_err_failed'.tr;
}

/// Горячая линия: свои сообщения (и анонимные с этого телефона), а у
/// комплаенс-офицера — ещё и все сообщения.
class ComplianceScreen extends StatefulWidget {
  const ComplianceScreen({Key? key}) : super(key: key);

  @override
  State<ComplianceScreen> createState() => _ComplianceScreenState();
}

class _ComplianceScreenState extends State<ComplianceScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  ComplianceList _data = const ComplianceList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await fetchCompliance();
      if (!mounted) return;
      setState(() {
        _data = data;
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

  Future<void> _create() async {
    final sent =
        await Get.to<ComplianceReport?>(() => const ComplianceFormScreen());
    if (sent == null || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('cp_sent'.tr)));
    _load();
  }

  Future<void> _open(ComplianceReport item) async {
    await Get.to(() => ComplianceDetailScreen(item: item));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final officer = _data.officer;
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _problem != null
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : officer
                ? TabBarView(children: [
                    _list(_data.queue, 'cp_empty_queue'.tr),
                    _list(_data.mine, 'cp_empty_mine'.tr, intro: true),
                  ])
                : _list(_data.mine, 'cp_empty_mine'.tr, intro: true);
    final scaffold = Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'cp_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: officer
            ? TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white70,
                indicatorColor: Colors.white,
                tabs: [
                  Tab(text: 'cp_tab_queue'.tr),
                  Tab(text: 'cp_tab_mine'.tr),
                ],
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('cp_new'),
        onPressed: _loading ? null : _create,
        icon: const Icon(Icons.shield_outlined),
        label: Text('cp_new'.tr),
      ),
      body: body,
    );
    return officer
        ? DefaultTabController(length: 2, child: scaffold)
        : scaffold;
  }

  Widget _list(List<ComplianceReport> items, String empty,
      {bool intro = false}) {
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        children: [
          if (intro)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text('cp_intro'.tr,
                  style: TextStyle(color: context.mutedColor)),
            ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(empty,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.mutedColor)),
            ),
          for (final item in items)
            InkWell(
              key: Key('cp_item_${item.id}'),
              onTap: () => _open(item),
              child: Container(
                margin: EdgeInsets.symmetric(
                    horizontal: Dimensions.width20, vertical: 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.cardSurface,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: context.cardShadow,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                              '№${item.id} · ${'cp_kind_${item.kind}'.tr}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                        Text('cp_status_${item.status}'.tr,
                            key: Key('cp_status_${item.id}'), style: muted),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(item.text,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                        [
                          item.anonymous
                              ? 'cp_anon_label'.tr
                              : item.author?.name ?? '',
                          if (item.createdAt != null)
                            DateFormat('dd.MM.yyyy').format(item.createdAt!),
                        ].where((s) => s.isNotEmpty).join(' · '),
                        style: muted),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ComplianceFormScreen extends StatefulWidget {
  const ComplianceFormScreen({Key? key}) : super(key: key);

  @override
  State<ComplianceFormScreen> createState() => _ComplianceFormScreenState();
}

class _ComplianceFormScreenState extends State<ComplianceFormScreen> {
  final _text = TextEditingController();
  String _kind = 'corruption';
  bool _anonymous = true;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_text.text.trim().length < 10) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('cp_err_text_required'.tr)));
      return;
    }
    setState(() => _sending = true);
    final result = await sendComplianceReport(
        kind: _kind, text: _text.text.trim(), anonymous: _anonymous);
    if (!mounted) return;
    setState(() => _sending = false);
    if (!result.ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_errorText(result))));
      return;
    }
    Get.back(result: result.item);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(title: BigText(content: 'cp_new'.tr, color: Colors.white)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text('cp_kind'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in complianceKinds)
                ChoiceChip(
                  key: Key('cp_kind_$k'),
                  label: Text('cp_kind_$k'.tr),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('cp_text'),
            controller: _text,
            maxLength: 4000,
            minLines: 5,
            maxLines: 12,
            decoration: InputDecoration(
                labelText: 'cp_text'.tr,
                alignLabelWithHint: true,
                border: const OutlineInputBorder()),
          ),
          SwitchListTile(
            key: const Key('cp_anonymous'),
            contentPadding: EdgeInsets.zero,
            value: _anonymous,
            title: Text('cp_anonymous'.tr),
            subtitle: Text('cp_anonymous_hint'.tr),
            onChanged: (v) => setState(() => _anonymous = v),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('cp_send'),
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.send),
              label: Text('cp_send'.tr),
            ),
          ),
        ],
      ),
    );
  }
}

/// Сообщение с перепиской. Анонимное открывается с ключом этого телефона.
class ComplianceDetailScreen extends StatefulWidget {
  const ComplianceDetailScreen({Key? key, required this.item})
      : super(key: key);

  final ComplianceReport item;

  @override
  State<ComplianceDetailScreen> createState() => _ComplianceDetailScreenState();
}

class _ComplianceDetailScreenState extends State<ComplianceDetailScreen> {
  late ComplianceReport _item = widget.item;
  bool _busy = false;

  Future<void> _act(String action, {String? prompt}) async {
    var text = '';
    if (prompt != null) {
      final values = await showDialog<Map<String, String>>(
        context: context,
        builder: (_) => FieldsDialog(
          title: prompt,
          fields: [DialogField('text', prompt, required: true)],
          okLabel: prompt,
        ),
      );
      if (values == null || !mounted) return;
      text = values['text'] ?? '';
    }
    setState(() => _busy = true);
    final result = await complianceAction(_item, action, text: text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.ok) {
      setState(() => _item = result.item!);
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_errorText(result))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final muted = TextStyle(fontSize: 12, color: context.mutedColor);
    final officerView = item.canHandle || (!item.isMine);
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
          title: BigText(
              content: '№${item.id} · ${'cp_kind_${item.kind}'.tr}',
              color: Colors.white)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Text(
              [
                'cp_status_${item.status}'.tr,
                item.anonymous ? 'cp_anon_label'.tr : item.author?.name ?? '',
                if (item.author?.department.isNotEmpty == true)
                  item.author!.department,
              ].where((s) => s.isNotEmpty).join(' · '),
              key: const Key('cp_header'),
              style: muted),
          const SizedBox(height: 8),
          SelectableText(item.text, style: const TextStyle(fontSize: 15)),
          for (final m in item.messages)
            Container(
              margin: EdgeInsets.only(
                  top: 10,
                  left: m.fromOfficer ? 0 : 32,
                  right: m.fromOfficer ? 32 : 0),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: m.fromOfficer
                    ? context.accentColor.withOpacity(0.10)
                    : context.cardSurface,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      m.fromOfficer
                          ? 'cp_officer'.tr
                          : (officerView ? 'cp_author'.tr : 'cp_you'.tr),
                      style: muted),
                  Text(m.text),
                ],
              ),
            ),
          if (item.resolution.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('cp_resolution'.tr, style: muted),
            Text(item.resolution, key: const Key('cp_resolution')),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (item.canReply)
                OutlinedButton.icon(
                  key: const Key('cp_reply'),
                  onPressed: _busy
                      ? null
                      : () => _act('message', prompt: 'cp_reply'.tr),
                  icon: const Icon(Icons.reply),
                  label: Text('cp_reply'.tr),
                ),
              if (item.canHandle && item.status == 'new')
                FilledButton(
                  key: const Key('cp_take'),
                  onPressed: _busy ? null : () => _act('take'),
                  child: Text('cp_take'.tr),
                ),
              if (item.canHandle)
                FilledButton(
                  key: const Key('cp_close'),
                  onPressed: _busy
                      ? null
                      : () => _act('close', prompt: 'cp_resolution'.tr),
                  child: Text('cp_close'.tr),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
