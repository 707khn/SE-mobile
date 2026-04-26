import 'package:flutter/material.dart';

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
  }) : super(key: key);

  final String hintText;
  final TextEditingController? controller;
  final IconButton? suffixIcon;
  final bool obscureText;
  final Color? backgroundColor;
  final double fontSize;
  final VoidCallback? onSubmitted;

  @override
  _CustomLoginFieldState createState() => _CustomLoginFieldState();
}

class _CustomLoginFieldState extends State<CustomLoginField> {
  late FocusNode _focusNode;
  bool _isFocused = false;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
    widget.controller?.addListener(_onTextChange);
    _hasText = widget.controller?.text.isNotEmpty ?? false;
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
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
          keyboardType: TextInputType.text,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          obscureText: widget.obscureText,
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
            hintText: widget.hintText,
            hintStyle: const TextStyle(color: Colors.grey),
            suffixIcon: _hasText
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18, color: Colors.grey),
                    onPressed: () => widget.controller?.clear(),
                  )
                : widget.suffixIcon,
            suffixIconConstraints: const BoxConstraints(),
          ),
        ),
      ),
    );
  }
}
