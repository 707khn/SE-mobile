import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/dimensions.dart';

class CustomLoginField extends StatefulWidget {
  const CustomLoginField({
    Key? key,
    required this.hintText,
    this.suffixIcon,
    required this.obscureText,
    this.controller,
    required this.fontSize,
    this.backgroundColor,
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
  final Color? backgroundColor;
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
  bool _isFocused = false;
  bool _hasText = false;
  late bool _obscured;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode.addListener(_onFocusChange);
    widget.controller?.addListener(_onTextChange);
    _hasText = widget.controller?.text.isNotEmpty ?? false;
    _obscured = widget.obscureText;
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    if (_ownsFocusNode) _focusNode.dispose();
    widget.controller?.removeListener(_onTextChange);
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {
      _isFocused = _focusNode.hasFocus;
    });
  }

  void _onTextChange() {
    final newHasText = widget.controller?.text.isNotEmpty ?? false;
    if (newHasText != _hasText) {
      setState(() => _hasText = newHasText);
    }
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = _isFocused ? Colors.white : widget.backgroundColor;

    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: Dimensions.width20 * 0.5),
        child: TextField(
          keyboardType: widget.keyboardType,
          maxLength: widget.maxLength,
          textInputAction: widget.textInputAction,
          obscureText: _obscured,
          controller: widget.controller,
          focusNode: _focusNode,
          onSubmitted: (_) => widget.onSubmitted?.call(),
          style: TextStyle(
            fontSize: widget.fontSize,
            color: Colors.black,
            fontFamily: 'Trebuchet MS',
          ),
          decoration: InputDecoration(
            focusedBorder: InputBorder.none,
            enabledBorder: InputBorder.none,
            counterText: '',
            hintText: widget.hintText,
            hintStyle: const TextStyle(color: Colors.grey),
            suffixIcon: _buildSuffixIcon(),
            suffixIconConstraints: const BoxConstraints(),
          ),
        ),
      ),
    );
  }

  // Password fields get a show/hide toggle; plain fields keep clear/paste.
  Widget _buildSuffixIcon() {
    if (widget.obscureText) {
      return IconButton(
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
        icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
        onPressed: () => widget.controller?.clear(),
      );
    }
    return IconButton(
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
