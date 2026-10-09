import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/app_theme.dart';
import 'package:se_mobile/utils/colors.dart';

/// Цвета разделов читаются и в тёмной теме.
///
/// Подобраны они под светлую: на тёмной карточке фиолетовый отчёт давал
/// контраст 1,6, красное меню и синий турникет — 2,9, фирменный зелёный —
/// 3,2. Мелкому тексту нужно не меньше 4,5, иначе подписи на главном экране
/// и заголовки разделов листка почти сливаются с фоном.
void main() {
  // Те, что стоят на карточках главного экрана, в листке и в отпуске.
  final sections = <Color>[
    AppColors.mainColor,
    AppColors.niceRed,
    const Color(0xFF1565C0),
    const Color(0xFFC62828),
    const Color(0xFF4527A0),
    const Color(0xFF6A1B9A),
    const Color(0xFF00695C),
    const Color(0xFFE65100),
    Colors.green.shade700,
    Colors.blue.shade700,
    Colors.orange.shade800,
  ];

  test('контраст считается по WCAG', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(contrastRatio(Colors.white, Colors.white), closeTo(1, 0.01));
  });

  test('на тёмной карточке каждый цвет раздела читается', () {
    for (final color in sections) {
      final shown = readableOn(color, AppColors.cardDark);
      expect(contrastRatio(shown, AppColors.cardDark), greaterThanOrEqualTo(4.5),
          reason: color.toARGB32().toRadixString(16));
    }
  });

  test('оттенок остаётся тем же, меняется только светлота', () {
    for (final color in sections) {
      final before = HSLColor.fromColor(color);
      final after = HSLColor.fromColor(readableOn(color, AppColors.cardDark));
      expect((after.hue - before.hue).abs(), lessThan(2));
      expect(after.lightness, greaterThanOrEqualTo(before.lightness));
    }
  });

  test('уже читаемый цвет не трогается', () {
    expect(readableOn(Colors.white, AppColors.cardDark), Colors.white);
    expect(readableOn(AppColors.mainColorDark, AppColors.cardDark),
        AppColors.mainColorDark);
  });

  Future<Color> shownIn(WidgetTester tester, ThemeData theme) async {
    late Color shown;
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Builder(builder: (context) {
        shown = context.readable(const Color(0xFF4527A0));
        return const SizedBox();
      }),
    ));
    return shown;
  }

  testWidgets('в светлой теме цвет раздела — как есть', (tester) async {
    expect(await shownIn(tester, AppTheme.light), const Color(0xFF4527A0));
  });

  testWidgets('в тёмной — осветлённый', (tester) async {
    final shown = await shownIn(tester, AppTheme.dark);
    expect(contrastRatio(shown, AppColors.cardDark), greaterThanOrEqualTo(4.5));
  });
}
