import 'package:get/get.dart';

import 'ui_scale.dart';

/// Размеры: отступы, радиусы, кегли.
///
/// Названия — это размер на **эталонном телефоне 392×800**: `fontSize14` там
/// и есть четырнадцать. На других экранах всё пропорционально, но с
/// ограничением — см. [uiScale].
///
/// Прежде пропорция была без ограничения, и это било по тем, у кого телефон
/// хуже: на экране 320×640 «четырнадцатый» кегль выходил **11,5** — мельче,
/// чем читается в цеху, — а на планшете раздувался до **22,9**. Меньший экран
/// требует относительно более крупного текста, а не более мелкого.
///
/// Считаются при обращении, а не один раз при загрузке класса: поворот экрана,
/// раскладной телефон и режим двух окон меняют размеры, а запомненные при
/// старте остались бы прежними.
class Dimensions {
  static double get screenHeight => Get.context?.height ?? kReferenceHeight;
  static double get screenWidth => Get.context?.width ?? kReferenceWidth;

  static double get _v => uiScale(screenHeight, kReferenceHeight);
  static double get _h => uiScale(screenWidth, kReferenceWidth);

  static double get height30 => 30 * _v;
  static double get height35 => 35 * _v;
  static double get height60 => 60 * _v;
  static double get height100 => 100 * _v;
  static double get height120 => 120 * _v;

  static double get width20 => 20 * _h;
  static double get width40 => 40 * _h;
  static double get width70 => 70 * _h;
  static double get width120 => 120 * _h;

  // Кегли множатся ещё и на системный размер шрифта — он берётся в main.dart
  // и ограничен там же. Здесь только поправка на экран.
  static double get fontSize14 => 14 * _v;
  static double get fontSize16 => 16 * _v;
  static double get fontSize18 => 18 * _v;
  static double get fontSize20 => 20 * _v;
  static double get fontSize25 => 25 * _v;
  static double get fontSize30 => 30 * _v;

  static double get radius25 => 25 * _v;
  static double get radius50 => 50 * _v;
}
