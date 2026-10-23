import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Поле диалога [FieldsDialog]: ключ ответа, подпись, клавиатура.
class DialogField {
  const DialogField(this.name, this.label,
      {this.number = false, this.required = false, this.initial = ''});

  final String name;
  final String label;
  final bool number;
  final bool required;
  final String initial;
}

/// Несколько коротких полей в диалоге — поездка, показания на возврате.
///
/// Возвращает {name: введённое} или null, если передумали. Контроллеры
/// живут в самом диалоге, как у [TextPromptDialog].
class FieldsDialog extends StatefulWidget {
  const FieldsDialog(
      {Key? key,
      required this.title,
      required this.fields,
      required this.okLabel})
      : super(key: key);

  final String title;
  final List<DialogField> fields;
  final String okLabel;

  @override
  State<FieldsDialog> createState() => _FieldsDialogState();
}

class _FieldsDialogState extends State<FieldsDialog> {
  late final Map<String, TextEditingController> _controllers = {
    for (final f in widget.fields)
      f.name: TextEditingController(text: f.initial)
  };

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _complete => widget.fields.every(
      (f) => !f.required || _controllers[f.name]!.text.trim().isNotEmpty);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in widget.fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  key: Key('field_${f.name}'),
                  controller: _controllers[f.name],
                  keyboardType: f.number
                      ? const TextInputType.numberWithOptions(decimal: true)
                      : TextInputType.text,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: f.label),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
        TextButton(
          key: const Key('fields_ok'),
          onPressed: _complete
              ? () => Navigator.pop(context, {
                    for (final e in _controllers.entries)
                      e.key: e.value.text.trim()
                  })
              : null,
          child: Text(widget.okLabel),
        ),
      ],
    );
  }
}
