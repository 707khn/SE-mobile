import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../requests/stock_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';

/// Новая заявка на ТМЦ: куда, с какого склада и список позиций.
class StockRequestFormScreen extends StatefulWidget {
  const StockRequestFormScreen({Key? key}) : super(key: key);

  @override
  State<StockRequestFormScreen> createState() => _StockRequestFormScreenState();
}

const _lastPurposeKey = 'stock_last_purpose';
const _lastWarehouseKey = 'stock_last_warehouse';
const _maxLines = 30;

class _LineInput {
  final name = TextEditingController();
  final quantity = TextEditingController();
  String unit = 'шт';

  void dispose() {
    name.dispose();
    quantity.dispose();
  }
}

class _StockRequestFormScreenState extends State<StockRequestFormScreen> {
  final _purpose = TextEditingController();
  int? _warehouse;
  final List<_LineInput> _lines = [_LineInput()];
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        if (_purpose.text.isEmpty) {
          _purpose.text = prefs.getString(_lastPurposeKey) ?? '';
        }
        final saved = prefs.getInt(_lastWarehouseKey);
        if (stockWarehouses.contains(saved)) _warehouse = saved;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _purpose.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  String _errorText(String? code) {
    for (final key in ['stock_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _send() async {
    final purpose = _purpose.text.trim();
    if (purpose.isEmpty) {
      setState(() => _error = 'stock_err_purpose_required'.tr);
      return;
    }
    final lines = <StockLine>[];
    for (final input in _lines) {
      final name = input.name.text.trim();
      final rawQty = input.quantity.text.trim();
      // Пустая строка внизу списка — не ошибка, а просто незаполненная.
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
    final result = await createStockRequest(
        purpose: purpose, lines: lines, warehouse: _warehouse);
    if (!mounted) return;
    if (result.ok) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_lastPurposeKey, purpose);
        if (_warehouse == null) {
          await prefs.remove(_lastWarehouseKey);
        } else {
          await prefs.setInt(_lastWarehouseKey, _warehouse!);
        }
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pop(result.item);
      return;
    }
    setState(() {
      _sending = false;
      _error = _errorText(result.error);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'stock_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            key: const Key('stock_purpose'),
            controller: _purpose,
            maxLength: 300,
            decoration: InputDecoration(
              labelText: 'stock_purpose'.tr,
              hintText: 'stock_purpose_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          Text('stock_warehouse'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final n in stockWarehouses)
                ChoiceChip(
                  label: Text('stock_warehouse_n'.trParams({'n': '$n'})),
                  selected: _warehouse == n,
                  onSelected: (_) => setState(() => _warehouse = n),
                ),
              ChoiceChip(
                label: Text('stock_warehouse_any'.tr),
                selected: _warehouse == null,
                onSelected: (_) => setState(() => _warehouse = null),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text('stock_lines'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (var i = 0; i < _lines.length; i++) _lineRow(i),
          if (_lines.length < _maxLines)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('stock_add_line'),
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
                key: const Key('stock_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('stock_send'),
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
              key: Key('stock_line_name_$index'),
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
              key: Key('stock_line_qty_$index'),
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
