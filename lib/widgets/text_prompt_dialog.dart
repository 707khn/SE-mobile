import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Спросить текст к действию: причину возврата, замечания, что исправили.
///
/// Возвращает введённое (может быть пустым, если не [required]) или null,
/// если передумали. Поле живёт в самом диалоге: контроллер, закрытый сразу
/// после pop, ломает анимацию закрытия.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog(
      {Key? key,
      required this.title,
      required this.hint,
      this.required = false})
      : super(key: key);

  final String title;
  final String hint;
  final bool required;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('prompt_text'),
        controller: _text,
        autofocus: true,
        maxLines: 3,
        maxLength: 1000,
        decoration: InputDecoration(hintText: widget.hint),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text('cancel'.tr)),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _text,
          builder: (context, value, _) => TextButton(
            key: const Key('prompt_ok'),
            onPressed: widget.required && value.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, value.text.trim()),
            child: Text(widget.title),
          ),
        ),
      ],
    );
  }
}
