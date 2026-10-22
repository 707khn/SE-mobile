import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../functions/barcode_decode.dart';
import '../functions/export_share.dart';
import '../requests/inventory_request.dart';
import '../requests/stock_balance_request.dart' show stockQuantity;
import '../utils/app_theme.dart';
import '../utils/load_problem.dart';
import '../widgets/custom_text.dart';
import '../widgets/fields_dialog.dart';
import '../widgets/load_error_view.dart';

String _date(DateTime? at) =>
    at == null ? '' : DateFormat('dd.MM.yyyy HH:mm').format(at);

String _warehouse(String name) =>
    name.isEmpty ? 'inv_no_name_warehouse'.tr : name;

String _signed(double value) =>
    value > 0 ? '+${stockQuantity(value)}' : '−${stockQuantity(-value)}';

String _errorText(InventoryResult result) {
  final key = 'inv_err_${result.error}';
  return result.error != null && key.tr != key ? key.tr : 'it_err_failed'.tr;
}

/// Снимок штрихкода камерой и его разбор; null — не сняли или не прочли.
typedef BarcodePhoto = Future<String?> Function();

Future<String?> _photoBarcode() async {
  final file = await ImagePicker()
      .pickImage(source: ImageSource.camera, maxWidth: 1600, maxHeight: 1600);
  if (file == null) return null;
  return decodeBarcodeInBackground(await file.readAsBytes());
}

/// Пересчёты складов: идущие и с подведённым итогом.
class InventoryScreen extends StatefulWidget {
  const InventoryScreen({Key? key, this.photo}) : super(key: key);

  final BarcodePhoto? photo;

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  InventoryDesk _desk = const InventoryDesk();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final desk = await fetchInventory();
      if (!mounted) return;
      setState(() {
        _desk = desk;
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

  void _show(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _open(int id) async {
    await Get.to(() => InventoryCountScreen(countId: id, photo: widget.photo));
    if (mounted) _load();
  }

  Future<void> _start() async {
    if (_desk.warehouses.isEmpty) {
      _show('inv_no_warehouses'.tr);
      return;
    }
    final warehouse = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('inv_pick_warehouse'.tr),
        children: [
          for (final (i, w) in _desk.warehouses.indexed)
            SimpleDialogOption(
              key: Key('inv_warehouse_$i'),
              onPressed: () => Navigator.pop(context, w.name),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_warehouse(w.name)),
                subtitle: Text('inv_warehouse_items'
                    .trParams({'count': '${w.items}', 'date': _date(w.asOf)})),
              ),
            ),
        ],
      ),
    );
    if (warehouse == null || !mounted) return;
    setState(() => _busy = true);
    final result = await startInventory(warehouse);
    if (!mounted) return;
    setState(() => _busy = false);
    final id = result.countId;
    if (result.ok && id != null) {
      await _open(id);
    } else if (result.error == 'exists' && id != null) {
      _show('inv_already_running'.tr);
      await _open(id);
    } else {
      _show(_errorText(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : _problem != null
            ? LoadErrorView(problem: _problem, onRetry: _load)
            : RefreshIndicator(
                onRefresh: _load,
                child: _desk.counts.isEmpty
                    ? ListView(children: [
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                              _desk.warehouses.isEmpty
                                  ? 'inv_no_warehouses'.tr
                                  : 'inv_empty'.tr,
                              textAlign: TextAlign.center),
                        ),
                      ])
                    : ListView.separated(
                        itemCount: _desk.counts.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) => _row(_desk.counts[i]),
                      ),
              );
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'inv_title'.tr, color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      floatingActionButton: _loading || _problem != null
          ? null
          : FloatingActionButton.extended(
              key: const Key('inv_start'),
              onPressed: _busy ? null : _start,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text('inv_start'.tr),
            ),
      body: body,
    );
  }

  Widget _row(InventoryCount count) {
    final color = context.readable(
        count.open ? const Color(0xFF1565C0) : const Color(0xFF546E7A));
    return ListTile(
      key: Key('inv_count_${count.id}'),
      onTap: () => _open(count.id),
      title: Text(_warehouse(count.warehouse)),
      subtitle: Text([
        'inv_progress'.trParams({
          'counted': '${count.counted}',
          'lines': '${count.lines}',
          'diff': '${count.differences}',
        }),
        'inv_started'.trParams({
          'date': _date(count.startedAt),
          'name': count.startedBy?.name ?? '',
        }),
      ].join('\n')),
      isThreeLine: true,
      trailing: Text('inv_status_${count.status}'.tr,
          style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }
}

/// Книга расхождений для акта: позиции, где факт не сошёлся с 1С.
///
/// В идущем пересчёте не посчитанное ещё не расхождение и в файл не идёт;
/// после итога оно — недостача целиком.
List<int>? buildInventoryExcel(InventorySheet sheet) {
  final rows = [
    for (final line in sheet.lines)
      if (line.diff != null && line.diff != 0) line
  ];
  if (rows.isEmpty) return null;
  final excel = Excel.createExcel();
  final name = 'inv_sheet'.tr;
  final table = excel[name];
  table.appendRow([
    TextCellValue(_warehouse(sheet.count.warehouse)),
    TextCellValue('inv_as_of'.trParams({'date': _date(sheet.count.asOf)})),
  ]);
  table.appendRow([
    for (final key in const [
      'inv_col_code',
      'inv_col_name',
      'inv_col_unit',
      'inv_col_expected',
      'inv_col_counted',
      'inv_col_diff',
    ])
      TextCellValue(key.tr)
  ]);
  for (final line in rows) {
    table.appendRow([
      TextCellValue(line.code),
      TextCellValue(line.name),
      TextCellValue(line.unit),
      DoubleCellValue(line.expected),
      DoubleCellValue(line.counted ?? 0),
      DoubleCellValue(line.diff ?? 0),
    ]);
  }
  if (name != 'Sheet1') excel.delete('Sheet1');
  return excel.save();
}

/// Один пересчёт: код со сканера или камеры, сколько насчитали, итог.
class InventoryCountScreen extends StatefulWidget {
  const InventoryCountScreen({Key? key, required this.countId, this.photo})
      : super(key: key);

  final int countId;
  final BarcodePhoto? photo;

  @override
  State<InventoryCountScreen> createState() => _InventoryCountScreenState();
}

class _InventoryCountScreenState extends State<InventoryCountScreen> {
  final _code = TextEditingController();
  final _codeFocus = FocusNode();
  final _search = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  LoadProblem? _problem;
  InventorySheet? _sheet;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    _codeFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final sheet = await fetchInventoryCount(widget.countId);
      if (!mounted) return;
      setState(() {
        _sheet = sheet;
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

  void _show(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  /// После каждого кода — снова в строку кода: сканер читает следующий.
  void _ready() {
    _code.clear();
    if (mounted) _codeFocus.requestFocus();
  }

  Future<void> _lookup(String raw) async {
    final code = raw.trim();
    if (code.isEmpty || _busy) return;
    setState(() => _busy = true);
    final result = await scanInventory(widget.countId, barcode: code);
    if (!mounted) return;
    setState(() => _busy = false);
    final line = result.line;
    if (result.ok && line != null) {
      await _count(line);
    } else if (result.error == 'unknown_code') {
      await _unknown(code);
    } else {
      _show(_errorText(result));
    }
    _ready();
  }

  Future<void> _photo() async {
    String? code;
    try {
      code = await (widget.photo ?? _photoBarcode)();
    } catch (_) {
      code = null;
    }
    if (!mounted) return;
    if (code == null) {
      _show('inv_no_code_on_photo'.tr);
      return;
    }
    _code.text = code;
    await _lookup(code);
  }

  Future<void> _count(InventoryLine line, {String? barcode}) async {
    final answer = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => _QuantityDialog(line: line),
    );
    if (answer == null || !mounted) return;
    final (quantity, set) = answer;
    setState(() => _busy = true);
    final result = await scanInventory(widget.countId,
        lineId: line.id, barcode: barcode, quantity: quantity, set: set);
    if (!mounted) return;
    setState(() => _busy = false);
    final saved = result.line;
    if (!result.ok || saved == null) {
      _show(_errorText(result));
      return;
    }
    _show('inv_saved'.trParams({
      'name': saved.name,
      'qty': '${stockQuantity(saved.counted ?? 0)} ${saved.unit}'.trim(),
    }));
    await _load();
  }

  Future<void> _unknown(String code) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('inv_unknown'.trParams({'code': code})),
        content: Text('inv_unknown_hint'.tr),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('cancel'.tr)),
          TextButton(
              key: const Key('inv_unknown_extra'),
              onPressed: () => Navigator.pop(context, 'extra'),
              child: Text('inv_add_extra'.tr)),
          TextButton(
              key: const Key('inv_unknown_bind'),
              onPressed: () => Navigator.pop(context, 'bind'),
              child: Text('inv_bind'.tr)),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'bind') {
      final line = await showDialog<InventoryLine>(
        context: context,
        builder: (_) => _LinePickerDialog(lines: _sheet?.lines ?? const []),
      );
      if (line == null || !mounted) return;
      await _count(line, barcode: code);
    } else {
      await _extra(barcode: code);
    }
  }

  Future<void> _extra({String? barcode}) async {
    final fields = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => FieldsDialog(
        title: 'inv_extra_title'.tr,
        fields: [
          DialogField('name', 'inv_name'.tr, required: true),
          DialogField('unit', 'inv_unit'.tr),
          DialogField('quantity', 'inv_quantity'.tr,
              number: true, required: true),
        ],
        okLabel: 'inv_add'.tr,
      ),
    );
    if (fields == null || !mounted) return;
    setState(() => _busy = true);
    final result =
        await addInventoryExtra(widget.countId, fields, barcode: barcode);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok) {
      _show(_errorText(result));
      return;
    }
    await _load();
  }

  Future<void> _menu(String action) async {
    final sheet = _sheet;
    if (sheet == null) return;
    switch (action) {
      case 'export':
        final bytes = buildInventoryExcel(sheet);
        if (bytes == null) {
          _show('inv_no_diffs'.tr);
          return;
        }
        await saveAndShare(context,
            'inventory_${_warehouse(sheet.count.warehouse)}', 'xlsx', bytes);
      case 'close':
        final sure = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('inv_close'.tr),
            content: Text('inv_close_confirm'.tr),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('cancel'.tr)),
              TextButton(
                  key: const Key('inv_close_ok'),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text('inv_close'.tr)),
            ],
          ),
        );
        if (sure != true || !mounted) return;
        await _action('close');
      case 'remove':
        if (await _action('remove') && mounted) Get.back();
    }
  }

  Future<bool> _action(String action) async {
    setState(() => _busy = true);
    final result = await inventoryAction(widget.countId, action);
    if (!mounted) return false;
    setState(() => _busy = false);
    if (!result.ok) {
      _show(_errorText(result));
      return false;
    }
    if (action != 'remove') await _load();
    return true;
  }

  List<InventoryLine> _visible(InventorySheet sheet) {
    final query = _search.text.trim().toLowerCase();
    return [
      for (final line in sheet.lines)
        if ((_filter == 'all' ||
                (_filter == 'left' && line.counted == null) ||
                (_filter == 'diff' && line.diff != null && line.diff != 0)) &&
            (query.isEmpty ||
                line.name.toLowerCase().contains(query) ||
                line.code.toLowerCase().contains(query)))
          line
    ];
  }

  @override
  Widget build(BuildContext context) {
    final sheet = _sheet;
    final count = sheet?.count;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(
            content:
                count == null ? 'inv_title'.tr : _warehouse(count.warehouse),
            color: Colors.white),
        actions: [
          if (sheet != null)
            PopupMenuButton<String>(
              key: const Key('inv_menu'),
              enabled: !_busy,
              onSelected: _menu,
              itemBuilder: (_) => [
                PopupMenuItem(
                    key: const Key('inv_menu_export'),
                    value: 'export',
                    child: Text('inv_export'.tr)),
                if (sheet.count.open)
                  PopupMenuItem(
                      key: const Key('inv_menu_close'),
                      value: 'close',
                      child: Text('inv_close'.tr)),
                if (sheet.count.open && sheet.count.counted == 0)
                  PopupMenuItem(
                      key: const Key('inv_menu_remove'),
                      value: 'remove',
                      child: Text('inv_remove'.tr)),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _problem != null || sheet == null
              ? LoadErrorView(problem: _problem, onRetry: _load)
              : _body(sheet),
    );
  }

  Widget _body(InventorySheet sheet) {
    final count = sheet.count;
    final lines = _visible(sheet);
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          color: context.accentColor.withOpacity(0.08),
          child: Text(
            [
              'inv_progress'.trParams({
                'counted': '${count.counted}',
                'lines': '${count.lines}',
                'diff': '${count.differences}',
              }),
              'inv_as_of'.trParams({'date': _date(count.asOf)}),
              if (!count.open) 'inv_status_closed'.tr,
            ].join('\n'),
            style: TextStyle(color: context.accentColor),
          ),
        ),
        if (count.open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const Key('inv_code'),
                  controller: _code,
                  focusNode: _codeFocus,
                  autofocus: true,
                  enabled: !_busy,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _lookup,
                  decoration: InputDecoration(
                    labelText: 'inv_code_hint'.tr,
                    helperText: 'inv_code_help'.tr,
                    helperMaxLines: 2,
                    prefixIcon: const Icon(Icons.qr_code),
                  ),
                ),
              ),
              IconButton(
                key: const Key('inv_camera'),
                icon: const Icon(Icons.photo_camera_outlined),
                tooltip: 'inv_camera'.tr,
                onPressed: _busy ? null : _photo,
              ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: TextField(
            key: const Key('inv_search'),
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'inv_search'.tr,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(spacing: 8, children: [
            for (final f in const ['all', 'left', 'diff'])
              ChoiceChip(
                key: Key('inv_filter_$f'),
                label: Text('inv_filter_$f'.tr),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.separated(
              itemCount: lines.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _line(lines[i], count.open),
            ),
          ),
        ),
        if (count.open)
          SafeArea(
            top: false,
            child: TextButton.icon(
              key: const Key('inv_extra'),
              onPressed: _busy ? null : () => _extra(),
              icon: const Icon(Icons.add),
              label: Text('inv_add_extra'.tr),
            ),
          ),
      ],
    );
  }

  Widget _line(InventoryLine line, bool open) {
    final diff = line.diff;
    final color = diff == null || diff == 0
        ? null
        : context.readable(
            diff < 0 ? const Color(0xFFC62828) : const Color(0xFFE65100));
    final unit = line.unit.isEmpty ? '' : ' ${line.unit}';
    return ListTile(
      key: Key('inv_line_${line.id}'),
      onTap: open && !_busy ? () => _count(line) : null,
      title: Text(line.name),
      subtitle: Text([
        if (line.code.isNotEmpty) line.code,
        line.extra
            ? 'inv_extra_badge'.tr
            : 'inv_expected'
                .trParams({'qty': '${stockQuantity(line.expected)}$unit'}),
      ].join(' · ')),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            line.counted == null
                ? 'inv_not_counted'.tr
                : 'inv_counted'
                    .trParams({'qty': '${stockQuantity(line.counted!)}$unit'}),
            style: TextStyle(
                fontSize: 13, color: line.counted == null ? Colors.grey : null),
          ),
          if (diff != null && diff != 0)
            Text(_signed(diff),
                style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Сколько насчитали: прибавить к посчитанному или записать вместо.
class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog({required this.line});

  final InventoryLine line;

  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  final _quantity = TextEditingController();

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  bool get _valid {
    final value = double.tryParse(_quantity.text.trim().replaceAll(',', '.'));
    return value != null && value >= 0;
  }

  void _done(bool set) => Navigator.pop(context, (_quantity.text.trim(), set));

  @override
  Widget build(BuildContext context) {
    final line = widget.line;
    final counted = line.counted;
    final unit = line.unit.isEmpty ? '' : ' ${line.unit}';
    return AlertDialog(
      title: Text(line.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!line.extra)
            Text('inv_expected'
                .trParams({'qty': '${stockQuantity(line.expected)}$unit'})),
          if (counted != null)
            Text('inv_already'
                .trParams({'qty': '${stockQuantity(counted)}$unit'})),
          TextField(
            key: const Key('inv_qty'),
            controller: _quantity,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _valid ? _done(false) : null,
            decoration: InputDecoration(
                labelText: 'inv_quantity'.tr, suffixText: line.unit),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
        if (counted != null)
          TextButton(
              key: const Key('inv_qty_set'),
              onPressed: _valid ? () => _done(true) : null,
              child: Text('inv_set'.tr)),
        TextButton(
            key: const Key('inv_qty_add'),
            onPressed: _valid ? () => _done(false) : null,
            child: Text('inv_add'.tr)),
      ],
    );
  }
}

/// Позиция пересчёта, к которой привязать незнакомый штрихкод.
class _LinePickerDialog extends StatefulWidget {
  const _LinePickerDialog({required this.lines});

  final List<InventoryLine> lines;

  @override
  State<_LinePickerDialog> createState() => _LinePickerDialogState();
}

class _LinePickerDialogState extends State<_LinePickerDialog> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.text.trim().toLowerCase();
    final words = query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final found = [
      for (final line in widget.lines)
        if (!line.extra &&
            words.every((w) =>
                line.name.toLowerCase().contains(w) ||
                line.code.toLowerCase().contains(w)))
          line
    ].take(50).toList();
    return AlertDialog(
      title: Text('inv_bind'.tr),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: Column(children: [
          TextField(
            key: const Key('inv_pick_search'),
            controller: _query,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                hintText: 'inv_search'.tr,
                prefixIcon: const Icon(Icons.search)),
          ),
          Expanded(
            child: ListView(children: [
              for (final line in found)
                ListTile(
                  key: Key('inv_pick_${line.id}'),
                  title: Text(line.name),
                  subtitle: Text(line.code),
                  onTap: () => Navigator.pop(context, line),
                ),
            ]),
          ),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
      ],
    );
  }
}
