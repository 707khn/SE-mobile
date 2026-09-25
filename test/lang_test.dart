import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/lang.dart';

/// Язык лежал в настройках строками «RU» и «KZ» и сравнивался с ними в пяти
/// файлах. Коды это не настоящие, и из-за них всё, что рисует сам Flutter,
/// оставалось русским; а умолчание разошлось — main.dart считал умолчанием
/// русский, а один из экранов при пустой настройке записывал «KZ».
void main() {
  test('сохранённое старыми сборками понимается', () {
    // Эти значения лежат на телефонах и никуда не денутся.
    expect(Lang.code('RU'), Lang.ru);
    expect(Lang.code('KZ'), Lang.kk);
  });

  test('новые коды тоже', () {
    expect(Lang.code('ru'), Lang.ru);
    expect(Lang.code('kk'), Lang.kk);
  });

  test('ничего не сохранено — русский', () {
    // Одно умолчание на всё приложение, а не своё у каждого экрана.
    expect(Lang.code(null), Lang.ru);
    expect(Lang.code(''), Lang.ru);
    expect(Lang.code('   '), Lang.ru);
    expect(Lang.code('какая-то ерунда'), Lang.ru);
  });

  test('регистр и пробелы не мешают', () {
    expect(Lang.code(' kZ '), Lang.kk);
    expect(Lang.code('Ru'), Lang.ru);
  });

  test('коды — настоящие, двухбуквенные', () {
    expect(Lang.ru, 'ru');
    expect(Lang.kk, 'kk');
  });

  test('isKazakh отвечает то же, что code', () {
    for (final stored in <String?>[null, '', 'RU', 'ru', 'KZ', 'kk', 'kz']) {
      expect(Lang.isKazakh(stored), Lang.code(stored) == Lang.kk,
          reason: 'разошлось на «$stored»');
    }
  });

  test('казахский объявляется Flutter только если он его знает', () {
    // Объявить язык, которого у Flutter нет, — значит уронить экран на
    // MaterialLocalizations.of. Список всегда начинается с русского и
    // содержит казахский ровно тогда, когда Flutter его поддерживает.
    final supported = Lang.supported.map((l) => l.languageCode).toList();
    expect(supported.first, Lang.ru);
    expect(supported.contains(Lang.kk), Lang.flutterKnowsKazakh);
    expect(supported.toSet().length, supported.length, reason: 'повторы');
  });

  test('без подготовленных казахских дат остаёмся на русских', () {
    // initDates() здесь не звали: Lang.dates обязан ответить «ru», а не
    // уронить экран на названии месяца.
    expect(Lang.dates, Lang.ru);
  });
}
