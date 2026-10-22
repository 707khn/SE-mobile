import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../requests/inspection_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';

/// Предъявить партию: что, сколько, где лежит и нужна ли ВП.
class InspectionFormScreen extends StatefulWidget {
  const InspectionFormScreen({Key? key}) : super(key: key);

  @override
  State<InspectionFormScreen> createState() => _InspectionFormScreenState();
}

const _lastPlaceKey = 'insp_last_place';
const _lastNeedsVpKey = 'insp_last_needs_vp';

class _InspectionFormScreenState extends State<InspectionFormScreen> {
  final _product = TextEditingController();
  final _quantity = TextEditingController();
  final _order = TextEditingController();
  final _place = TextEditingController();
  final _note = TextEditingController();
  bool _needsVp = false;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  /// Участок и «нужна ВП» у одного мастера почти всегда те же.
  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        if (_place.text.isEmpty) {
          _place.text = prefs.getString(_lastPlaceKey) ?? '';
        }
        _needsVp = prefs.getBool(_lastNeedsVpKey) ?? _needsVp;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _product.dispose();
    _quantity.dispose();
    _order.dispose();
    _place.dispose();
    _note.dispose();
    super.dispose();
  }

  String _errorText(String? code) {
    for (final key in ['insp_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _send() async {
    final product = _product.text.trim();
    final place = _place.text.trim();
    final quantity = int.tryParse(_quantity.text.trim());
    if (product.isEmpty) {
      setState(() => _error = 'insp_err_product_required'.tr);
      return;
    }
    if (quantity == null || quantity <= 0) {
      setState(() => _error = 'insp_err_bad_quantity'.tr);
      return;
    }
    if (place.isEmpty) {
      setState(() => _error = 'insp_err_place_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await createInspection(
      product: product,
      quantity: quantity,
      place: place,
      orderNo: _order.text.trim(),
      note: _note.text.trim(),
      needsVp: _needsVp,
    );
    if (!mounted) return;
    if (result.ok) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_lastPlaceKey, place);
        await prefs.setBool(_lastNeedsVpKey, _needsVp);
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
        title: BigText(content: 'insp_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            key: const Key('insp_product'),
            controller: _product,
            maxLength: 200,
            decoration:
                _field('insp_product'.tr, hint: 'insp_product_hint'.tr),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('insp_quantity'),
            controller: _quantity,
            keyboardType: TextInputType.number,
            decoration: _field('insp_quantity'.tr),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('insp_order'),
            controller: _order,
            maxLength: 100,
            decoration: _field('insp_order'.tr),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('insp_place'),
            controller: _place,
            maxLength: 200,
            decoration: _field('insp_place'.tr),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('insp_note'),
            controller: _note,
            maxLength: 1000,
            minLines: 2,
            maxLines: 5,
            decoration: _field('insp_note'.tr),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            key: const Key('insp_needs_vp'),
            contentPadding: EdgeInsets.zero,
            title: Text('insp_needs_vp'.tr),
            value: _needsVp,
            activeThumbColor: context.accentColor,
            onChanged:
                _sending ? null : (value) => setState(() => _needsVp = value),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('insp_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('insp_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('insp_new'.tr),
            ),
          ),
        ],
      ),
    );
  }
}
