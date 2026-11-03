import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/payslip_upload_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../utils/search_fold.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';
import 'payslip_screen.dart';
import 'payslip_upload_screen.dart';

final _money = NumberFormat('#,##0.00', 'ru_RU');

/// Раздел «Расчётные листы» — для расчётной группы, в версии для компьютера.
///
/// Загруженные месяцы, листки месяца списком и сам листок любого сотрудника.
/// Листки здесь не правят руками: источник — 1С, и поправленный там листок
/// загружают файлом заново. Перезагрузка заменяет листки только тех, кто есть
/// в файле, поэтому поправить одного человека — это файл на одного человека.
class PayslipsAdminScreen extends StatefulWidget {
  const PayslipsAdminScreen({Key? key}) : super(key: key);

  @override
  State<PayslipsAdminScreen> createState() => _PayslipsAdminScreenState();
}

class _PayslipsAdminScreenState extends State<PayslipsAdminScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  List<PayslipPeriodInfo> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await fetchPayslipAdminPeriods();
      if (!mounted) return;
      setState(() {
        _items = items;
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

  Future<void> _upload() async {
    await Get.to(() => const PayslipUploadScreen());
    if (mounted) _load();
  }

  Future<void> _open(PayslipPeriodInfo period) async {
    await Get.to(() => PayslipMonthScreen(period: period));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'psa_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('psa_add'),
        icon: const Icon(Icons.upload_file),
        label: Text('psa_add'.tr),
        onPressed: _upload,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : _list(context),
    );
  }

  Widget _list(BuildContext context) {
    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('psa_empty'.tr,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.mutedColor)),
        ),
      );
    }
    final when = DateFormat('dd.MM.yyyy HH:mm');
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        Text('psa_hint'.tr,
            style: TextStyle(color: context.mutedColor, height: 1.4)),
        const SizedBox(height: 12),
        for (final p in _items)
          Card(
            child: ListTile(
              key: Key('psa_period_${p.year}_${p.month}'),
              leading: const Icon(Icons.receipt_long),
              title: Text(p.title,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([
                'psa_count'.trParams({'count': '${p.count}'}),
                if (p.uploadedAt != null)
                  'psa_uploaded'.trParams({
                    'when': when.format(p.uploadedAt!),
                    'who': p.uploadedBy,
                  }),
              ].join('\n')),
              isThreeLine: p.uploadedAt != null,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _open(p),
            ),
          ),
      ],
    );
  }
}

/// Листки одного месяца: поиск, листок сотрудника, удаление.
class PayslipMonthScreen extends StatefulWidget {
  const PayslipMonthScreen({Key? key, required this.period}) : super(key: key);

  final PayslipPeriodInfo period;

  @override
  State<PayslipMonthScreen> createState() => _PayslipMonthScreenState();
}

class _PayslipMonthScreenState extends State<PayslipMonthScreen> {
  bool _loading = true;
  LoadProblem? _problem;
  List<PayslipRow> _rows = const [];
  String _query = '';

  PayslipPeriodInfo get _period => widget.period;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await fetchPayslipMonth(_period.year, _period.month);
      if (!mounted) return;
      setState(() {
        _rows = rows;
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

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('cancel'.tr),
            ),
            FilledButton(
              key: const Key('psa_confirm'),
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade700),
              onPressed: () => Navigator.pop(context, true),
              child: Text('psa_delete'.tr),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _delete({PayslipRow? row}) async {
    final ok = row == null
        ? await _confirm(
            'psa_delete_month_title'.trParams({'period': _period.title}),
            'psa_delete_month_text'.trParams({'count': '${_rows.length}'}))
        : await _confirm('psa_delete_one_title'.tr,
            'psa_delete_one_text'.trParams({
              'name': row.fullName,
              'period': _period.title,
            }));
    if (!ok) return;
    final problem = await deletePayslips(_period.year, _period.month,
        employeeId: row?.employeeId);
    if (!mounted) return;
    if (problem != null) {
      final (title, _) = problemTexts(problem);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(title)));
      return;
    }
    if (row == null) {
      Get.back();
      return;
    }
    _load();
  }

  Future<void> _replace() async {
    await Get.to(() => const PayslipUploadScreen());
    if (mounted) _load();
  }

  List<PayslipRow> get _visible {
    final q = foldForSearch(_query.trim());
    if (q.isEmpty) return _rows;
    return _rows
        .where((r) =>
            foldForSearch('${r.fullName} ${r.department} ${r.employeeId}')
                .contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: _period.title, color: Colors.white),
        actions: [
          IconButton(
            key: const Key('psa_replace'),
            icon: const Icon(Icons.upload_file),
            tooltip: 'psa_replace'.tr,
            onPressed: _replace,
          ),
          IconButton(
            key: const Key('psa_delete_month'),
            icon: const Icon(Icons.delete_outline),
            tooltip: 'psa_delete_month'.tr,
            onPressed: _loading || _rows.isEmpty ? null : () => _delete(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: TextField(
                        key: const Key('psa_search'),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'psa_search'.tr,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Text('psa_fix_hint'.tr,
                          style: TextStyle(
                              color: context.mutedColor, fontSize: 12)),
                    ),
                    Expanded(child: _list(context)),
                  ],
                ),
    );
  }

  Widget _list(BuildContext context) {
    final rows = _visible;
    if (rows.isEmpty) {
      return Center(
        child: Text('psa_not_found'.tr,
            style: TextStyle(color: context.mutedColor)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final r = rows[i];
        return ListTile(
          key: Key('psa_row_${r.employeeId}'),
          title: Text(r.fullName),
          subtitle: Text(r.department.isEmpty
              ? r.employeeId
              : '${r.department} · ${r.employeeId}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${_money.format(r.netPay)} ₸',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              PopupMenuButton<String>(
                key: Key('psa_menu_${r.employeeId}'),
                onSelected: (_) => _delete(row: r),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'delete',
                    child: Text('psa_delete_one'.tr),
                  ),
                ],
              ),
            ],
          ),
          onTap: () => Get.to(() => PayslipPage(
                employeeId: r.employeeId,
                employeeName: r.fullName,
                initialMonth: DateTime(_period.year, _period.month),
              )),
        );
      },
    );
  }
}
