import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/search_fold.dart';

/// У двенадцати человек из 123 в имени есть буквы, которых на русской
/// раскладке нет: «Асқаров Қайрат Мейрамұлы» — Генеральный директор.
/// Телефон открывает русскую клавиатуру, и найти их можно было, только
/// переключив раскладку и вспомнив, где там `қ`.
void main() {
  test('казахские буквы ищутся с русской раскладки', () {
    expect(matchesQuery('Асқаров Қайрат Мейрамұлы', 'Аскаров'), isTrue);
    expect(matchesQuery('Тілеуғали Еркінғали Тілеуғалиұлы', 'Тилеугали'),
        isTrue);
    expect(matchesQuery('Омаргалиева Меруетгүль Кабылкаковна', 'меруетгуль'),
        isTrue);
    expect(matchesQuery('Ділдәбеков Еркебұлан Дуанұлы', 'дилдабеков'), isTrue);
  });

  test('и наоборот: набранное по-казахски находит написанное по-русски', () {
    expect(matchesQuery('Нургали Дастан', 'Нұрғали'), isTrue);
  });

  test('настоящее написание ищется тоже', () {
    expect(matchesQuery('Асқаров Қайрат Мейрамұлы', 'Асқаров'), isTrue);
  });

  test('регистр не мешает', () {
    expect(matchesQuery('АСҚАРОВ ҚАЙРАТ', 'аскаров'), isTrue);
    expect(matchesQuery('асқаров қайрат', 'АСКАРОВ'), isTrue);
  });

  test('«ё» набирают через «е» почти всегда', () {
    expect(matchesQuery('Фёдоров Пётр', 'Федоров'), isTrue);
    expect(matchesQuery('Федоров Петр', 'Пётр'), isTrue);
  });

  test('чужое всё так же не находится', () {
    expect(matchesQuery('Асқаров Қайрат', 'Мусипов'), isFalse);
    expect(matchesQuery('Иванов', 'Петров'), isFalse);
  });

  test('пустой запрос подходит всему', () {
    expect(matchesQuery('Асқаров', ''), isTrue);
  });

  test('свёртка не склеивает разных людей', () {
    // Иначе «поиск стал находить всех» было бы не лучше, чем «не находит
    // никого».
    expect(foldForSearch('Асқаров'), isNot(foldForSearch('Мусипов')));
    expect(foldForSearch('Нұрғали'), foldForSearch('Нургали'));
  });
}
