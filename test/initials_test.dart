import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/initials.dart';

void main() {
  test('первые буквы фамилии и имени', () {
    expect(initialsOf('Тестов Аман Тестович'), 'ТА');
    expect(initialsOf('тестов аман'), 'ТА');
    expect(initialsOf('Тестов'), 'Т');
  });

  test('лишние пробелы не роняют', () {
    expect(initialsOf('Тестов  Аман'), 'ТА');
    expect(initialsOf('  Тестов \t Аман  '), 'ТА');
    expect(initialsOf(' Тестов'), 'Т');
  });

  test('пустое имя — вопрос', () {
    expect(initialsOf(''), '?');
    expect(initialsOf('   '), '?');
  });
}
