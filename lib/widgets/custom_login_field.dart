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
  }) : super(key: key);

  final String hintText;
  final TextEditingController? controller;
  final IconButton? suffixIcon;
  final bool obscureText;
  final Color? backgroundColor;
  final double fontSize;

  @override
  _CustomLoginFieldState createState() => _CustomLoginFieldState();
}

class _CustomLoginFieldState extends State<CustomLoginField> {
  late FocusNode _focusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    setState(() {
      _isFocused = _focusNode.hasFocus;
    });
  }

  @override
  Widget build(BuildContext context) {
    final backgroundColor = _isFocused ? Colors.white : widget.backgroundColor;

    return Container(
      color: backgroundColor,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: Dimensions.width20*0.5), // Добавлен внутренний отступ по горизонтали
        child: TextField(
          keyboardType: TextInputType.text,
          obscureText: widget.obscureText,
          controller: widget.controller,
          focusNode: _focusNode,
          style: TextStyle(
            fontSize: widget.fontSize,
            color: Colors.black,
            //fontWeight: FontWeight.bold,
            fontFamily: 'Trebuchet MS',
          ),
          decoration: InputDecoration(
            focusedBorder: InputBorder.none,
            enabledBorder: InputBorder.none,
            hintText: widget.hintText,
            suffixIcon: widget.suffixIcon,
            suffixIconConstraints: BoxConstraints(),
          ),
        ),
      ),
    );
  }
}
