import 'package:flutter/material.dart';

class AppColors{
  static const Color mainColor = Color(0xff018041);
  static const Color niceWhite = Color(0xfffffafa);
  static const Color niceRed = Color(0xffb00B20);
  static const Color gradientColor1 = Color(0xff308f60);
  static const Color gradientColor2 = Color(0xff49cc8b);

  /// Осветлённый фирменный зелёный для тёмной темы: #018041 на тёмном фоне
  /// почти неразличим, кнопки и выделения на нём пропадают.
  static const Color mainColorDark = Color(0xff3fbe7e);
  static const Color niceRedDark = Color(0xffe4707f);

  // Поверхности. Нейтральные, но со сдвигом в зелёный — чтобы фон не спорил
  // с фирменным цветом, а держал его.
  static const Color pageLight = Color(0xfff5f7f4);
  static const Color cardLight = Color(0xffffffff);
  static const Color inkLight = Color(0xff17201a);
  static const Color mutedLight = Color(0xff667069);
  static const Color hairlineLight = Color(0xffdde3df);

  static const Color pageDark = Color(0xff111512);
  static const Color cardDark = Color(0xff1b211d);
  static const Color inkDark = Color(0xffe6ede8);
  static const Color mutedDark = Color(0xff98a49d);
  static const Color hairlineDark = Color(0xff2c352f);
}