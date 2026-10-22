import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../requests/tech_question_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';

/// Вопрос в ТО: о чём, по какому изделию, где и что не сходится.
class TechQuestionFormScreen extends StatefulWidget {
  const TechQuestionFormScreen({Key? key}) : super(key: key);

  @override
  State<TechQuestionFormScreen> createState() => _TechQuestionFormScreenState();
}

class _TechQuestionFormScreenState extends State<TechQuestionFormScreen> {
  final _product = TextEditingController();
  final _document = TextEditingController();
  final _operation = TextEditingController();
  final _text = TextEditingController();
  String _kind = 'drawing';
  bool _urgent = false;
  bool _sending = false;
  String? _error;
  List<String> _suggested = const [];
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_product, _document, _operation, _text]) {
      c.dispose();
    }
    super.dispose();
  }

  void _productChanged(String text) {
    _debounce?.cancel();
    if (text.trim().length < 2) {
      setState(() => _suggested = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      List<String> found;
      try {
        found = await suggestTechProducts(text.trim());
      } catch (_) {
        found = const [];
      }
      if (!mounted || _product.text.trim() != text.trim()) return;
      // Уже введено ровно это — подсказывать нечего.
      setState(() => _suggested = found
          .where((p) => p.toLowerCase() != text.trim().toLowerCase())
          .take(5)
          .toList());
    });
  }

  String _errorText(String? code) {
    for (final key in ['tq_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _send() async {
    final product = _product.text.trim();
    final text = _text.text.trim();
    if (product.isEmpty) {
      setState(() => _error = 'tq_err_product_required'.tr);
      return;
    }
    if (text.isEmpty) {
      setState(() => _error = 'tq_err_text_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await askTechQuestion(
      kind: _kind,
      product: product,
      text: text,
      document: _document.text.trim(),
      operation: _operation.text.trim(),
      urgent: _urgent,
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'tq_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text('tq_kind'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final kind in techQuestionKinds)
                ChoiceChip(
                  key: Key('tq_kind_$kind'),
                  label: Text('tq_kind_$kind'.tr),
                  selected: _kind == kind,
                  onSelected: (_) => setState(() => _kind = kind),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('tq_product'),
            controller: _product,
            maxLength: 200,
            onChanged: _productChanged,
            decoration: InputDecoration(
              labelText: 'tq_product'.tr,
              hintText: 'tq_product_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          if (_suggested.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                for (final p in _suggested)
                  ActionChip(
                    label: Text(p),
                    onPressed: () => setState(() {
                      _product.text = p;
                      _suggested = const [];
                    }),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  key: const Key('tq_document'),
                  controller: _document,
                  maxLength: 100,
                  decoration: InputDecoration(
                    labelText: 'tq_document'.tr,
                    border: const OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  key: const Key('tq_operation'),
                  controller: _operation,
                  maxLength: 100,
                  decoration: InputDecoration(
                    labelText: 'tq_operation'.tr,
                    border: const OutlineInputBorder(),
                    counterText: '',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('tq_text'),
            controller: _text,
            maxLength: 4000,
            minLines: 3,
            maxLines: 10,
            decoration: InputDecoration(
              labelText: 'tq_text'.tr,
              hintText: 'tq_text_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 4),
          Text('tq_no_files'.tr,
              style: TextStyle(fontSize: 12, color: context.mutedColor)),
          SwitchListTile(
            key: const Key('tq_urgent'),
            contentPadding: EdgeInsets.zero,
            title: Text('tq_urgent'.tr),
            value: _urgent,
            onChanged: (v) => setState(() => _urgent = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('tq_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('tq_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('tq_send'.tr),
            ),
          ),
        ],
      ),
    );
  }
}
