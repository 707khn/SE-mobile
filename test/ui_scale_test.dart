import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/ui_scale.dart';

/// Размеры множились на отношение экрана к эталонному без всякого предела, и
/// выходило наоборот: у кого телефон хуже, у того и буквы мельче. На экране
/// 320×640 «четырнадцатый» кегль был 11,5 — а это как раз те телефоны, с
/// которых читают расчётный лист на солнце и в перчатках.
void main() {
  test('на эталонном телефоне ничего не меняется', () {
    expect(uiScale(kReferenceHeight, kReferenceHeight), 1.0);
    expect(uiScale(kReferenceWidth, kReferenceWidth), 1.0);
  });

  test('на дешёвом телефоне текст не проваливается', () {
    // 640 / 800 = 0.8 — было бы 11,2 при «четырнадцатом» кегле.
    final small = uiScale(640, kReferenceHeight);
    expect(small, greaterThanOrEqualTo(0.92));
    expect(14 * small, greaterThan(12.5));
  });

  test('на планшете размеры не раздуваются', () {
    // 1280 / 800 = 1.6 — было бы 22,4.
    final tablet = uiScale(1280, kReferenceHeight);
    expect(tablet, lessThanOrEqualTo(1.15));
    expect(14 * tablet, lessThan(17));
  });

  test('между пределами — обычная пропорция', () {
    expect(uiScale(840, kReferenceHeight), closeTo(1.05, 0.001));
    expect(uiScale(760, kReferenceHeight), closeTo(0.95, 0.001));
  });

  test('растёт с экраном, а не скачет', () {
    var previous = 0.0;
    for (var size = 200.0; size <= 2000; size += 50) {
      final value = uiScale(size, kReferenceHeight);
      expect(value, greaterThanOrEqualTo(previous));
      previous = value;
    }
  });

  test('бессмысленный размер не ломает вёрстку', () {
    // Ноль приходит до первой отрисовки, отрицательного не бывает — но
    // деление на такое дало бы бесконечность и разъехавшийся экран.
    expect(uiScale(0, kReferenceHeight), 1.0);
    expect(uiScale(-100, kReferenceHeight), 1.0);
    expect(uiScale(800, 0), 1.0);
  });
}
