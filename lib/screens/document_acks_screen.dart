import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/documents_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';

/// Кто ознакомился с документом и кто ещё нет — вместо листа с подписями.
///
/// «Ещё нет» — по подразделениям: начальнику отдела проще напомнить своим,
/// чем составителю обзванивать всех по одному.
class DocumentAcksScreen extends StatefulWidget {
  const DocumentAcksScreen({Key? key, required this.document}) : super(key: key);

  final CompanyDocument document;

  @override
  State<DocumentAcksScreen> createState() => _DocumentAcksScreenState();
}

class _DocumentAcksScreenState extends State<DocumentAcksScreen> {
  bool _loading = true;
  bool _error = false;
  LoadProblem? _problem;
  int _expected = 0;
  List<Map<String, dynamic>> _acked = [];
  List<Map<String, dynamic>> _waiting = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final body = await getDocumentAcks(widget.document.id);
    if (!mounted) return;
    if (body['message'] != 'Success') {
      setState(() {
        _loading = false;
        _error = true;
        _problem = problemIn(body);
      });
      return;
    }
    List<Map<String, dynamic>> people(Object? raw) =>
        ((raw as List?) ?? []).whereType<Map<String, dynamic>>().toList();
    setState(() {
      _expected = (body['expected'] as int?) ?? 0;
      _acked = people(body['acked']);
      _waiting = people(body['waiting']);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: context.pageColor,
        appBar: AppBar(
          title: BigText(content: 'documents_who_acked'.tr, color: Colors.white),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'refresh'.tr,
              onPressed: _loading ? null : _load,
            ),
          ],
          bottom: TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [
              Tab(text: 'documents_acked_tab'.trParams({'count': '${_acked.length}'})),
              Tab(text: 'documents_waiting_tab'.trParams({'count': '${_waiting.length}'})),
            ],
          ),
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error) return LoadErrorView(problem: _problem, onRetry: _load);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.document.title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _expected == 0 ? 0 : (_acked.length / _expected).clamp(0, 1),
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
              ),
              const SizedBox(height: 6),
              Text(
                'documents_acked_of'.trParams({
                  'done': '${_acked.length}',
                  'total': '$_expected',
                }),
                style: TextStyle(fontSize: 13, color: context.mutedColor),
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            children: [
              _list(_acked, showTime: true),
              _list(_waiting, byDepartment: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _list(List<Map<String, dynamic>> people,
      {bool showTime = false, bool byDepartment = false}) {
    if (people.isEmpty) {
      return Center(child: Text('documents_nobody'.tr));
    }
    final rows = <Widget>[];
    String? department;
    for (final p in people) {
      final dept = (p['department'] as String?) ?? '';
      if (byDepartment && dept != department) {
        department = dept;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
          child: Text(dept.isEmpty ? '—' : dept,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.mutedColor)),
        ));
      }
      final at = DateTime.tryParse((p['at'] as String?) ?? '');
      rows.add(ListTile(
        dense: true,
        title: Text((p['full_name'] as String?) ?? ''),
        subtitle: !byDepartment && dept.isNotEmpty ? Text(dept) : null,
        trailing: showTime && at != null
            ? Text(DateFormat('dd.MM HH:mm').format(at.toLocal()),
                style: TextStyle(fontSize: 12, color: context.mutedColor))
            : null,
      ));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(children: rows),
    );
  }
}
