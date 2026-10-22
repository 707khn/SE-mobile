import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../requests/repair_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';
import 'repair_requests_screen.dart';

/// Новая заявка на ремонт. Закрывается с созданной заявкой в результате.
class RepairRequestFormScreen extends StatefulWidget {
  const RepairRequestFormScreen(
      {Key? key, this.picker, this.photosAllowed = true})
      : super(key: key);

  /// Подменяется в проверках: настоящей камеры там нет.
  final ImagePicker? picker;

  /// Сервер может отключить фото: снимать на территории можно не везде.
  final bool photosAllowed;

  @override
  State<RepairRequestFormScreen> createState() =>
      _RepairRequestFormScreenState();
}

/// Место и телефон у мастера из раза в раз одни и те же — запоминаем.
const _lastPlaceKey = 'repair_last_place';
const _lastPhoneKey = 'repair_last_phone';
const _maxPhotos = 3;

class _RepairRequestFormScreenState extends State<RepairRequestFormScreen> {
  final _place = TextEditingController();
  final _equipment = TextEditingController();
  final _description = TextEditingController();
  final _phone = TextEditingController();
  String _category = 'equipment';
  bool _stopped = false;
  final List<Uint8List> _photos = [];
  bool _sending = false;
  String? _error;

  late final ImagePicker _picker = widget.picker ?? ImagePicker();

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      if (_place.text.isEmpty) {
        _place.text = prefs.getString(_lastPlaceKey) ?? '';
      }
      if (_phone.text.isEmpty) {
        _phone.text = prefs.getString(_lastPhoneKey) ?? '';
      }
    } catch (_) {
      // Не вспомнили — человек наберёт сам.
    }
  }

  @override
  void dispose() {
    _place.dispose();
    _equipment.dispose();
    _description.dispose();
    _phone.dispose();
    super.dispose();
  }

  String get _service =>
      _category == 'equipment' || _category == 'electric'
          ? 'engineer'
          : 'facility';

  Future<void> _addPhoto(ImageSource source) async {
    try {
      final file = await _picker.pickImage(
          source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      setState(() => _photos.add(bytes));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('it_err_failed'.tr)));
    }
  }

  String _errorText(String? code) {
    for (final key in ['repair_err_$code', 'it_err_$code']) {
      if (code != null && key.tr != key) return key.tr;
    }
    return 'it_err_failed'.tr;
  }

  Future<void> _send() async {
    final place = _place.text.trim();
    final description = _description.text.trim();
    if (place.isEmpty) {
      setState(() => _error = 'repair_err_place_required'.tr);
      return;
    }
    if (description.length < 3) {
      setState(() => _error = 'it_err_description_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await createRepairRequest(
      category: _category,
      place: place,
      description: description,
      equipment: repairAsksEquipment.contains(_category)
          ? _equipment.text.trim()
          : '',
      phone: _phone.text.trim(),
      stopped: _stopped && repairCanStop.contains(_category),
      photos: widget.photosAllowed ? _photos : const [],
    );
    if (!mounted) return;
    if (result.ok) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_lastPlaceKey, place);
        await prefs.setString(_lastPhoneKey, _phone.text.trim());
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
        title: BigText(content: 'repair_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text('repair_category'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final category in repairCategories)
                ChoiceChip(
                  avatar: Icon(repairCategoryIcon(category), size: 18),
                  label: Text('repair_cat_$category'.tr),
                  selected: _category == category,
                  onSelected: (_) => setState(() => _category = category),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'repair_goes_to'
                .trParams({'service': 'repair_service_$_service'.tr}),
            key: const Key('repair_goes_to'),
            style: TextStyle(fontSize: 12, color: context.mutedColor),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('repair_place'),
            controller: _place,
            maxLength: 100,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'repair_place'.tr,
              hintText: 'repair_place_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          if (repairAsksEquipment.contains(_category)) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('repair_equipment'),
              controller: _equipment,
              maxLength: 100,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'repair_equipment'.tr,
                hintText: 'repair_equipment_hint'.tr,
                border: const OutlineInputBorder(),
                counterText: '',
              ),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            key: const Key('repair_description'),
            controller: _description,
            maxLines: 5,
            minLines: 3,
            maxLength: 2000,
            decoration: InputDecoration(
              labelText: 'it_description'.tr,
              hintText: 'repair_description_hint'.tr,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          if (repairCanStop.contains(_category))
            SwitchListTile(
              key: const Key('repair_stopped'),
              contentPadding: EdgeInsets.zero,
              value: _stopped,
              onChanged: (value) => setState(() => _stopped = value),
              title: Text('repair_stopped'.tr,
                  style: const TextStyle(fontSize: 14)),
              activeThumbColor: repairStoppedColor,
            ),
          const SizedBox(height: 4),
          TextField(
            controller: _phone,
            maxLength: 50,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: 'it_phone'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          if (widget.photosAllowed) ...[
            Text('it_photos'.trParams({'count': '${_photos.length}'}),
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _photos.length; i++) _thumb(i),
                if (_photos.length < _maxPhotos) ...[
                  OutlinedButton.icon(
                    onPressed: _sending
                        ? null
                        : () => _addPhoto(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: Text('it_photo_camera'.tr),
                  ),
                  OutlinedButton.icon(
                    onPressed: _sending
                        ? null
                        : () => _addPhoto(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text('it_photo_gallery'.tr),
                  ),
                ],
              ],
            ),
          ] else
            Text('repair_photos_off'.tr,
                key: const Key('repair_photos_off'),
                style: TextStyle(fontSize: 12, color: context.mutedColor)),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                key: const Key('repair_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('repair_send'),
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

  Widget _thumb(int index) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(_photos[index],
              width: 88, height: 88, fit: BoxFit.cover),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: InkWell(
            onTap: _sending
                ? null
                : () => setState(() => _photos.removeAt(index)),
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                  color: Colors.black54, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 16, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}
