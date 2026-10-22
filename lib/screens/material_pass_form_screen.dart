import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/material_pass_request.dart';
import '../requests/stock_request.dart' show StockLine, stockUnits;
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';

/// Оформить материальный пропуск: куда, кто везёт, в какой день и что.
class MaterialPassFormScreen extends StatefulWidget {
  const MaterialPassFormScreen({Key? key}) : super(key: key);

  @override
  State<MaterialPassFormScreen> createState() => _MaterialPassFormScreenState();
}

const _maxLines = 30;
const _maxDaysAhead = 14;

class _LineInput {
  final name = TextEditingController();
  final quantity = TextEditingController();
  String unit = 'шт';

  void dispose() {
    name.dispose();
    quantity.dispose();
  }
}

class _MaterialPassFormScreenState extends State<MaterialPassFormScreen> {
  final _purpose = TextEditingController();
  final _carrier = TextEditingController();
  final _vehicle = TextEditingController();
  final List<_LineInput> _lines = [_LineInput()];
  late DateTime _date = _today;
  bool _sending = false;
  String? _error;

  static DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _purpose.dispose();
    _carrier.dispose();
    _vehicle.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  String _errorText(String? code) {
    for (final key in ['pass_err_$code', 'stock_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: _today,
      lastDate: _today.add(const Duration(days: _maxDaysAhead)),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  Future<void> _send() async {
    final purpose = _purpose.text.trim();
    final carrier = _carrier.text.trim();
    if (purpose.isEmpty) {
      setState(() => _error = 'pass_err_purpose_required'.tr);
      return;
    }
    if (carrier.isEmpty) {
      setState(() => _error = 'pass_err_carrier_required'.tr);
      return;
    }
    final lines = <StockLine>[];
    for (final input in _lines) {
      final name = input.name.text.trim();
      final rawQty = input.quantity.text.trim();
      if (name.isEmpty && rawQty.isEmpty) continue;
      if (name.isEmpty) {
        setState(() => _error = 'stock_err_line_name_required'.tr);
        return;
      }
      final qty = double.tryParse(rawQty.replaceAll(',', '.'));
      if (qty == null || qty <= 0) {
        setState(() => _error = 'stock_err_bad_quantity'.tr);
        return;
      }
      lines.add(StockLine(name: name, quantity: qty, unit: input.unit));
    }
    if (lines.isEmpty) {
      setState(() => _error = 'stock_err_lines_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await createMaterialPass(
      purpose: purpose,
      carrier: carrier,
      vehicle: _vehicle.text.trim(),
      exitDate: _date,
      lines: lines,
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
    final tomorrow = _today.add(const Duration(days: 1));
    final other = _date != _today && _date != tomorrow;
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'pass_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            key: const Key('pass_purpose'),
            controller: _purpose,
            maxLength: 300,
            decoration:
                _field('pass_purpose'.tr, hint: 'pass_purpose_hint'.tr),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pass_carrier'),
            controller: _carrier,
            maxLength: 200,
            decoration:
                _field('pass_carrier'.tr, hint: 'pass_carrier_hint'.tr),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pass_vehicle'),
            controller: _vehicle,
            maxLength: 20,
            textCapitalization: TextCapitalization.characters,
            decoration: _field('pass_vehicle'.tr),
          ),
          const SizedBox(height: 12),
          Text('pass_exit_date'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                key: const Key('pass_today'),
                label: Text('pass_today'.tr),
                selected: _date == _today,
                onSelected: (_) => setState(() => _date = _today),
              ),
              ChoiceChip(
                key: const Key('pass_tomorrow'),
                label: Text('pass_tomorrow'.tr),
                selected: _date == tomorrow,
                onSelected: (_) => setState(() => _date = tomorrow),
              ),
              ChoiceChip(
                label: Text(other
                    ? DateFormat('dd.MM.yyyy').format(_date)
                    : 'pass_pick_date'.tr),
                selected: other,
                onSelected: (_) => _pickDate(),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('pass_lines'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (var i = 0; i < _lines.length; i++) _lineRow(i),
          if (_lines.length < _maxLines)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('pass_add_line'),
                onPressed: _sending
                    ? null
                    : () => setState(() => _lines.add(_LineInput())),
                icon: const Icon(Icons.add),
                label: Text('stock_add_line'.tr),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('pass_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('pass_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('it_send'.tr),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lineRow(int index) {
    final line = _lines[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: TextField(
              key: Key('pass_line_name_$index'),
              controller: line.name,
              maxLength: 200,
              decoration: InputDecoration(
                labelText: 'stock_line_name'.tr,
                border: const OutlineInputBorder(),
                isDense: true,
                counterText: '',
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 2,
            child: TextField(
              key: Key('pass_line_qty_$index'),
              controller: line.quantity,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'stock_line_qty'.tr,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 6),
          DropdownButton<String>(
            value: line.unit,
            items: [
              for (final unit in stockUnits)
                DropdownMenuItem(value: unit, child: Text(unit)),
            ],
            onChanged: (value) =>
                setState(() => line.unit = value ?? line.unit),
          ),
          if (_lines.length > 1)
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: _sending
                  ? null
                  : () => setState(() => _lines.removeAt(index).dispose()),
            ),
        ],
      ),
    );
  }
}
