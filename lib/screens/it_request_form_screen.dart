import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../requests/it_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';
import 'it_requests_screen.dart';

/// Новая заявка в ОИТиС. Закрывается с созданной заявкой в результате.
class ItRequestFormScreen extends StatefulWidget {
  const ItRequestFormScreen({Key? key, this.picker}) : super(key: key);

  /// Подменяется в проверках: настоящей камеры там нет.
  final ImagePicker? picker;

  @override
  State<ItRequestFormScreen> createState() => _ItRequestFormScreenState();
}

/// Кабинет и телефон у человека из раза в раз одни и те же — запоминаем.
const _lastRoomKey = 'it_last_room';
const _lastPhoneKey = 'it_last_phone';
const _maxPhotos = 3;

class _ItRequestFormScreenState extends State<ItRequestFormScreen> {
  final _room = TextEditingController();
  final _description = TextEditingController();
  final _phone = TextEditingController();
  String _category = 'printer';
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
      if (_room.text.isEmpty) _room.text = prefs.getString(_lastRoomKey) ?? '';
      if (_phone.text.isEmpty) {
        _phone.text = prefs.getString(_lastPhoneKey) ?? '';
      }
    } catch (_) {
      // Не вспомнили — человек наберёт сам.
    }
  }

  @override
  void dispose() {
    _room.dispose();
    _description.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _addPhoto(ImageSource source) async {
    try {
      // Снимок с телефона — 4–12 Мб. Для «какой принтер и что на экране»
      // хватает 1600 точек: это сотни килобайт, и по мобильному интернету
      // заявка уходит за секунды.
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

  Future<void> _send() async {
    final room = _room.text.trim();
    final description = _description.text.trim();
    if (room.isEmpty) {
      setState(() => _error = 'it_err_room_required'.tr);
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
    final result = await createItRequest(
      category: _category,
      room: room,
      description: description,
      phone: _phone.text.trim(),
      photos: _photos,
    );
    if (!mounted) return;
    if (result.ok) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_lastRoomKey, room);
        await prefs.setString(_lastPhoneKey, _phone.text.trim());
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).pop(result.item);
      return;
    }
    // Набранное не пропадает: экран остаётся, можно повторить.
    final key = 'it_err_${result.error}';
    setState(() {
      _sending = false;
      _error = result.error != null && key.tr != key ? key.tr : 'it_err_failed'.tr;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'it_new'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text('it_category'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final category in itCategories)
                ChoiceChip(
                  avatar: Icon(itCategoryIcon(category), size: 18),
                  label: Text('it_cat_$category'.tr),
                  selected: _category == category,
                  onSelected: (_) => setState(() => _category = category),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('it_room'),
            controller: _room,
            maxLength: 50,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'it_room'.tr,
              hintText: 'it_room_hint'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('it_description'),
            controller: _description,
            maxLines: 5,
            minLines: 3,
            maxLength: 2000,
            decoration: InputDecoration(
              labelText: 'it_description'.tr,
              hintText: 'it_description_hint'.tr,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
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
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                key: const Key('it_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              key: const Key('it_send'),
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
            onTap: _sending ? null : () => setState(() => _photos.removeAt(index)),
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
