import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../requests/payslip_upload_request.dart';
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/load_error_view.dart';

/// Выбранный файл: имя и содержимое.
typedef PickedFile = ({String name, Uint8List bytes});

/// Окно «Открыть файл» Windows с отбором файлов Excel.
Future<PickedFile?> pickExcelFile() async {
  const group = XTypeGroup(label: 'Excel', extensions: ['xls', 'xlsx']);
  final file = await FileSelectorPlatform.instance
      .openFile(acceptedTypeGroups: const [group]);
  if (file == null) return null;
  return (name: file.name, bytes: await file.readAsBytes());
}

/// Загрузка расчётных листков из 1С — для расчётной группы, на компьютере.
///
/// Бухгалтер формирует в 1С отчёт «Расчетный листок» на всё предприятие и
/// сохраняет его в Excel. Здесь — выбрать этот файл, посмотреть, что в нём
/// нашлось (месяц, сколько листков, кого нет в приложении), и только потом
/// опубликовать: опубликованный листок сразу уходит пятистам людям
/// уведомлением, и ошибиться месяцем или файлом тут дорого.
class PayslipUploadScreen extends StatefulWidget {
  const PayslipUploadScreen({Key? key, this.pick = pickExcelFile})
      : super(key: key);

  /// Подменяется в тестах: окна выбора файла там нет.
  final Future<PickedFile?> Function() pick;

  @override
  State<PayslipUploadScreen> createState() => _PayslipUploadScreenState();
}

class _PayslipUploadScreenState extends State<PayslipUploadScreen> {
  PickedFile? _file;
  PayslipUploadSummary? _summary;
  String _busy = '';
  String _message = '';
  LoadProblem? _problem;

  Future<void> _choose() async {
    final file = await widget.pick();
    if (file == null || !mounted) return;
    setState(() {
      _file = file;
      _summary = null;
    });
    await _send(dryRun: true);
  }

  Future<void> _send({required bool dryRun}) async {
    final file = _file;
    if (file == null) return;
    setState(() {
      _busy = dryRun ? 'psu_checking'.tr : 'psu_publishing'.tr;
      _message = '';
      _problem = null;
    });
    final result =
        await uploadPayslips(file.name, file.bytes, dryRun: dryRun);
    if (!mounted) return;
    setState(() {
      _busy = '';
      _summary = result.summary ?? (dryRun ? null : _summary);
      _message = result.message;
      _problem = result.problem;
    });
  }

  Future<void> _publish() async {
    final summary = _summary;
    if (summary == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('psu_confirm_title'.tr),
        content: Text('psu_confirm_text'.trParams({
          'count': '${summary.count}',
          'period': summary.periods.join(', '),
        })),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('cancel'.tr),
          ),
          FilledButton(
            key: const Key('psu_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text('psu_publish'.tr),
          ),
        ],
      ),
    );
    if (ok == true) await _send(dryRun: false);
  }

  void _restart() => setState(() {
        _file = null;
        _summary = null;
        _message = '';
        _problem = null;
      });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'psu_title'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: _body(context),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    if (_busy.isNotEmpty) {
      return [
        const SizedBox(height: 48),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 16),
        Text(_busy, textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text('psu_wait'.tr,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.mutedColor)),
      ];
    }
    final summary = _summary;
    if (_problem != null) {
      return [
        SizedBox(
          height: 360,
          child: LoadErrorView(
              problem: _problem,
              onRetry: () => _send(dryRun: summary == null)),
        ),
      ];
    }
    if (summary != null && summary.published) return _done(context, summary);
    if (summary != null) return _preview(context, summary);
    return _start(context);
  }

  List<Widget> _start(BuildContext context) {
    final message = _message;
    return [
      Text('psu_how'.tr, style: const TextStyle(height: 1.5)),
      if (message.isNotEmpty) ...[
        const SizedBox(height: 20),
        Card(
          key: const Key('psu_error'),
          color: Colors.red.withValues(alpha: 0.08),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline,
                    color: context.readable(Colors.red.shade700)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(message.tr, style: const TextStyle(height: 1.4)),
                ),
              ],
            ),
          ),
        ),
      ],
      const SizedBox(height: 24),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          key: const Key('psu_choose'),
          icon: const Icon(Icons.upload_file),
          label: Text('psu_choose'.tr),
          onPressed: _choose,
        ),
      ),
    ];
  }

  Widget _line(String label, String value, {Key? key}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            Text(value,
                key: key,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      );

  List<Widget> _preview(BuildContext context, PayslipUploadSummary summary) {
    return [
      Text(_file?.name ?? '', style: TextStyle(color: context.mutedColor)),
      const SizedBox(height: 12),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(summary.periods.join(', '),
                  key: const Key('psu_period'),
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              _line('psu_count'.tr, '${summary.count}',
                  key: const Key('psu_count')),
              if (summary.replaced > 0) ...[
                _line('psu_new'.tr, '${summary.added}'),
                _line('psu_replaced'.tr, '${summary.replaced}'),
              ],
            ],
          ),
        ),
      ),
      if (summary.replaced > 0) ...[
        const SizedBox(height: 8),
        Text('psu_replaced_hint'.tr,
            style: TextStyle(color: context.mutedColor, height: 1.4)),
      ],
      if (summary.unknown.isNotEmpty) ...[
        const SizedBox(height: 12),
        Card(
          child: ExpansionTile(
            key: const Key('psu_unknown'),
            leading: Icon(Icons.person_search_outlined,
                color: context.readable(Colors.orange.shade800)),
            title: Text('psu_unknown'
                .trParams({'count': '${summary.unknown.length}'})),
            subtitle: Text('psu_unknown_hint'.tr),
            children: [
              for (final p in summary.unknown)
                ListTile(
                  dense: true,
                  title: Text(p.name.isEmpty ? p.id : p.name),
                  subtitle: Text(p.id),
                ),
            ],
          ),
        ),
      ],
      const SizedBox(height: 24),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FilledButton.icon(
            key: const Key('psu_publish'),
            icon: const Icon(Icons.send),
            label: Text('psu_publish'.tr),
            onPressed: _publish,
          ),
          OutlinedButton(
            onPressed: _choose,
            child: Text('psu_other_file'.tr),
          ),
        ],
      ),
    ];
  }

  List<Widget> _done(BuildContext context, PayslipUploadSummary summary) {
    return [
      const SizedBox(height: 24),
      Icon(Icons.check_circle_outline,
          size: 64, color: context.readable(Colors.green.shade700)),
      const SizedBox(height: 12),
      Text(
        'psu_done'.trParams({
          'count': '${summary.count}',
          'period': summary.periods.join(', '),
        }),
        key: const Key('psu_done'),
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Text('psu_done_hint'.tr,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.mutedColor)),
      const SizedBox(height: 24),
      Center(
        child: OutlinedButton(
          onPressed: _restart,
          child: Text('psu_again'.tr),
        ),
      ),
    ];
  }
}
