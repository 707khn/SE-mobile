import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/colors.dart';
import '../utils/dimensions.dart';

class CustomLoginField extends StatefulWidget {
  const CustomLoginField({
    Key? key,
    required this.hintText,
    this.suffixIcon,
    required this.obscureText,
    this.controller,
    required this.fontSize,
    this.onSubmitted,
    this.keyboardType = TextInputType.number,
    this.maxLength = 12,
    this.textInputAction = TextInputAction.done,
    this.focusNode,
  }) : super(key: key);

  final String hintText;
  final TextEditingController? controller;
  final IconButton? suffixIcon;
  final bool obscureText;
  final double fontSize;
  final VoidCallback? onSubmitted;
  final TextInputType keyboardType;
  final int maxLength;
  final TextInputAction textInputAction;

  /// Optional external focus node (e.g. so a previous field can focus this one).
  final FocusNode? focusNode;

  @override
  _CustomLoginFieldState createState() => _CustomLoginFieldState();
}

class _CustomLoginFieldState extends State<CustomLoginField> {
  late FocusNode _focusNode;
  bool _ownsFocusNode = false;
  bool _hasText = false;
  late bool _obscured;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _ownsFocusNode = widget.focusNode == null;
    widget.controller?.addListener(_onTextChange);
    _hasText = widget.controller?.text.isNotEmpty ?? false;
    _obscured = widget.obscureText;
  }

  @override
  void dispose() {
    if (_ownsFocusNode) _focusNode.dispose();
    widget.controller?.removeListener(_onTextChange);
    super.dispose();
  }

  void _onTextChange() {
    final newHasText = widget.controller?.text.isNotEmpty ?? false;
    if (newHasText != _hasText) {
      setState(() => _hasText = newHasText);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Рамка принадлежит самому полю, а не обёртке. Раньше поле лежало в
    // контейнере с серой заливкой и боковыми отступами, а сама заливка поля
    // была белой — от контейнера оставались видны две серые полоски по краям.
    return TextField(
      keyboardType: widget.keyboardType,
      maxLength: widget.maxLength,
      textInputAction: widget.textInputAction,
      obscureText: _obscured,
      controller: widget.controller,
      focusNode: _focusNode,
      onSubmitted: (_) => widget.onSubmitted?.call(),
      cursorColor: AppColors.mainColor,
      style: TextStyle(
        fontSize: widget.fontSize,
        color: Colors.black,
        fontFamily: 'Trebuchet MS',
      ),
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        isDense: false,
        contentPadding: EdgeInsets.symmetric(
          horizontal: Dimensions.width20 * 0.7,
          vertical: Dimensions.height30 * 0.45,
        ),
        // В покое — тонкая серая рамка: белое поле на почти белой карточке
        // иначе не видно. При вводе — зелёный контур.
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.mainColor, width: 2),
        ),
        counterText: '',
        hintText: widget.hintText,
        hintStyle: const TextStyle(color: Colors.grey),
        suffixIcon: Padding(
          padding: const EdgeInsets.only(right: 6),
          child: _buildSuffixIcon(),
        ),
        // Иконка больше не прижимается к рамке: без отступа она упиралась в
        // контур, который раньше рисовала внешняя обёртка.
        suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      ),
    );
  }

  // Password fields get a show/hide toggle; plain fields keep clear/paste.
  Widget _buildSuffixIcon() {
    if (widget.obscureText) {
      return IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        icon: Icon(
          _obscured ? Icons.visibility_off : Icons.visibility,
          size: 20,
          color: Colors.grey,
        ),
        onPressed: () => setState(() => _obscured = !_obscured),
      );
    }
    if (_hasText) {
      return IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
        onPressed: () => widget.controller?.clear(),
      );
    }
    return IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      icon: const Icon(Icons.content_paste_rounded, size: 18, color: Colors.grey),
      onPressed: () async {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text?.trim() ?? '';
        if (text.isNotEmpty && widget.controller != null) {
          widget.controller!.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
        }
      },
    );
  }
}
