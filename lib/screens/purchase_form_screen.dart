import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../requests/purchase_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';

/// Заявка на закупку: для чего, к какому числу и что купить.
class PurchaseFormScreen extends StatefulWidget {
  const PurchaseFormScreen({Key? key}) : super(key: key);

  @override
  State<PurchaseFormScreen> createState() => _PurchaseFormScreenState();
}

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

class _PurchaseFormScreenState extends State<PurchaseFormScreen> {
  final _purpose = TextEditingController();
  final List<_LineInput> _lines = [_LineInput()];
  DateTime? _neededBy;
  bool _urgent = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _purpose.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  String _errorText(String? code) {
    for (final key in ['purch_err_$code', 'stock_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _neededBy ?? today.add(const Duration(days: 14)),
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (picked != null && mounted) setState(() => _neededBy = picked);
  }

  Future<void> _send() async {
    final purpose = _purpose.text.trim();
    if (purpose.isEmpty) {
      setState(() => _error = 'purch_err_purpose_required'.tr);
      return;
    }
    final lines = <PurchaseLine>[];
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
      lines.add(PurchaseLine(name: name, quantity: qty, unit: input.unit));
    }
    if (lines.isEmpty) {
      setState(() => _error = 'stock_err_lines_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await createPurchase(
        purpose: purpose, lines: lines, neededBy: _neededBy, urgent: _urgent);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'purch_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            key: const Key('purch_purpose'),
            controller: _purpose,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: 'purch_purpose'.tr,
              hintText: 'purch_purpose_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          Text('purch_needed_by'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text('purch_needed_by_none'.tr),
                selected: _neededBy == null,
                onSelected: (_) => setState(() => _neededBy = null),
              ),
              ChoiceChip(
                key: const Key('purch_needed_by'),
                label: Text(_neededBy == null
                    ? 'pass_pick_date'.tr
                    : DateFormat('dd.MM.yyyy').format(_neededBy!)),
                selected: _neededBy != null,
                onSelected: (_) => _pickDate(),
              ),
            ],
          ),
          SwitchListTile(
            key: const Key('purch_urgent'),
            contentPadding: EdgeInsets.zero,
            title: Text('purch_urgent'.tr),
            subtitle: Text('purch_urgent_hint'.tr,
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
            value: _urgent,
            activeThumbColor: const Color(0xFFC62828),
            onChanged:
                _sending ? null : (value) => setState(() => _urgent = value),
          ),
          const SizedBox(height: 8),
          Text('purch_lines'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (var i = 0; i < _lines.length; i++) _lineRow(i),
          if (_lines.length < _maxLines)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('purch_add_line'),
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
                key: const Key('purch_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('purch_send'),
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
              key: Key('purch_line_name_$index'),
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
              key: Key('purch_line_qty_$index'),
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
              for (final unit in purchaseUnits)
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
