import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../requests/assignment_request.dart' show AssignPerson;

/// Выбрать сотрудника поиском по ФИО или должности.
///
/// Как выбор исполнителя в поручениях, но с поиском, который задаёт экран:
/// у каждого раздела свой круг, кого можно вписать.
class PersonPickerDialog extends StatefulWidget {
  const PersonPickerDialog(
      {Key? key, required this.title, required this.search})
      : super(key: key);

  final String title;
  final Future<List<AssignPerson>> Function(String query) search;

  @override
  State<PersonPickerDialog> createState() => _PersonPickerDialogState();
}

class _PersonPickerDialogState extends State<PersonPickerDialog> {
  final _query = TextEditingController();
  Timer? _debounce;
  List<AssignPerson> _found = const [];
  bool _searching = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(text));
  }

  Future<void> _search(String text) async {
    final seq = ++_seq;
    setState(() => _searching = true);
    List<AssignPerson> found;
    try {
      found = await widget.search(text.trim());
    } catch (_) {
      found = const [];
    }
    // Ответ на старый запрос пришёл позже нового — не показываем.
    if (!mounted || seq != _seq) return;
    setState(() {
      _found = found;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              key: const Key('person_search'),
              controller: _query,
              onChanged: _changed,
              decoration: InputDecoration(
                hintText: 'asg_search'.tr,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      )
                    : null,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                child: ListView(
                  children: [
                    for (final p in _found)
                      ListTile(
                        key: Key('person_${p.id}'),
                        dense: true,
                        title: Text(p.name),
                        subtitle: Text(
                            [p.jobTitle, p.department]
                                .where((s) => s.isNotEmpty)
                                .join(', '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(context, p),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
      ],
    );
  }
}
