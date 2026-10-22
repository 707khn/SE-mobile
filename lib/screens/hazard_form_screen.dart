import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../requests/hazard_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';
import 'hazards_screen.dart';

/// Сообщить об опасности: что, где, срочно ли; можно без имени.
class HazardFormScreen extends StatefulWidget {
  const HazardFormScreen({Key? key}) : super(key: key);

  @override
  State<HazardFormScreen> createState() => _HazardFormScreenState();
}

class _HazardFormScreenState extends State<HazardFormScreen> {
  final _place = TextEditingController();
  final _text = TextEditingController();
  String? _category;
  bool _urgent = false;
  bool _anonymous = false;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _place.dispose();
    _text.dispose();
    super.dispose();
  }

  String _errorText(String? code) {
    for (final key in ['hz_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _send() async {
    final place = _place.text.trim();
    final text = _text.text.trim();
    String? error;
    if (_category == null) {
      error = 'hz_err_bad_category'.tr;
    } else if (place.isEmpty) {
      error = 'hz_err_place_required'.tr;
    } else if (text.isEmpty) {
      error = 'hz_err_text_required'.tr;
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await reportHazard(
        category: _category!,
        place: place,
        text: text,
        urgent: _urgent,
        anonymous: _anonymous);
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
        title: BigText(content: 'hz_title'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text('hz_category'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final c in hazardCategories)
                ChoiceChip(
                  key: Key('hz_cat_$c'),
                  avatar: Icon(hazardIcon(c), size: 18),
                  label: Text('hz_cat_$c'.tr),
                  selected: _category == c,
                  onSelected: (_) => setState(() => _category = c),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('hz_place'),
            controller: _place,
            maxLength: 200,
            decoration: InputDecoration(
              labelText: 'hz_place'.tr,
              hintText: 'hz_place_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('hz_text'),
            controller: _text,
            maxLength: 2000,
            minLines: 3,
            maxLines: 8,
            decoration: InputDecoration(
              labelText: 'hz_text'.tr,
              hintText: 'hz_text_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            key: const Key('hz_urgent'),
            contentPadding: EdgeInsets.zero,
            title: Text('hz_urgent'.tr),
            value: _urgent,
            onChanged: (v) => setState(() => _urgent = v),
          ),
          SwitchListTile(
            key: const Key('hz_anonymous'),
            contentPadding: EdgeInsets.zero,
            title: Text('hz_anonymous'.tr),
            subtitle: Text('hz_anonymous_hint'.tr,
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
            value: _anonymous,
            onChanged: (v) => setState(() => _anonymous = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('hz_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('hz_send'),
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send),
              label: Text('hz_send'.tr),
            ),
          ),
        ],
      ),
    );
  }
}
