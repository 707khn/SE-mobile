import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../utils/dimensions.dart';


class BigText extends StatelessWidget {
  const BigText ({Key? key, required this.content, this.color, this.fontSize = 20, this.overflow = TextOverflow.ellipsis, this.textAlign = TextAlign.center, this.fontWeight = FontWeight.normal}) : super(key: key);

  final String content;
  final double fontSize;
  final TextOverflow overflow;
  final Color? color;
  final TextAlign? textAlign;
  final FontWeight fontWeight;

  @override
  Widget build(BuildContext context) {
    return Text(content, textAlign: textAlign, overflow: overflow, style: TextStyle(fontSize: fontSize == 20 ? Dimensions.fontSize20 : fontSize, color: color, fontWeight: fontWeight),);
  }
}

class MediumText extends StatelessWidget {
  const MediumText ({Key? key, required this.content, this.color, this.fontSize = 16, this.overflow = TextOverflow.ellipsis, this.textAlign = TextAlign.center, this.fontWeight = FontWeight.normal, required int maxLines}) : super(key: key);

  final String content;
  final double fontSize;
  final TextOverflow overflow;
  final Color? color;
  final TextAlign? textAlign;
  final FontWeight fontWeight;

  @override
  Widget build(BuildContext context) {
    return Text(content, textAlign: textAlign, overflow: overflow, style: TextStyle(fontSize: fontSize == 16 ? Dimensions.fontSize16 : fontSize, color: color, fontWeight: fontWeight),);
  }
}

class SmallText extends StatelessWidget {
  const SmallText ({Key? key, required this.content, this.color, this.fontSize = 14, this.overflow = TextOverflow.ellipsis, this.textAlign = TextAlign.center, this.fontWeight = FontWeight.normal}) : super(key: key);

  final String content;
  final double fontSize;
  final TextOverflow overflow;
  final Color? color;
  final TextAlign? textAlign;
  final FontWeight fontWeight;

  @override
  Widget build(BuildContext context) {
    return Text(content, textAlign: textAlign, overflow: overflow, style: TextStyle(fontSize: fontSize == 14 ? Dimensions.fontSize14 : fontSize, color: color, fontWeight: fontWeight),);
  }
}