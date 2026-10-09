import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/functions/sheet_name.dart';

/// Лист Excel не может называться длиннее 31 знака. Отчёт по проходам звал
/// лист по ФИО, а из 123 человек справочника у двенадцати ФИО длиннее:
/// «Пробамолдинова Айгуль Тестокаримовна» — 36 знаков. Такой файл Excel
/// открывать отказывается, и человек об этом узнаёт, уже скачав его.
void main() {
  test('короткое имя остаётся как есть', () {
    expect(excelSheetName('Иванов Иван', <String>{}), 'Иванов Иван');
  });

  test('длинное обрезается до тридцати одного знака', () {
    const long = 'Пробамолдинова Айгуль Тестокаримовна';
    expect(long.length, 36);
    final name = excelSheetName(long, <String>{});
    expect(name.length, lessThanOrEqualTo(31));
    expect(long.startsWith(name), isTrue, reason: 'обрезали не с конца');
  });

  test('запрещённые знаки убираются', () {
    final name = excelSheetName('Отдел [1] / цех: №2 * \\ ?', <String>{});
    for (final bad in <String>[':', '\\', '/', '?', '*', '[', ']']) {
      expect(name.contains(bad), isFalse, reason: 'остался $bad');
    }
    expect(name.trim(), name);
  });

  test('пустое имя листа недопустимо', () {
    expect(excelSheetName('', <String>{}), isNotEmpty);
    expect(excelSheetName('   ', <String>{}), isNotEmpty);
    expect(excelSheetName('***', <String>{}), isNotEmpty);
  });

  test('апострофы по краям Excel не принимает', () {
    expect(excelSheetName("'Иванов'", <String>{}), 'Иванов');
  });

  test('«History» занято самим Excel', () {
    expect(excelSheetName('History', <String>{}).toLowerCase(),
        isNot('history'));
  });

  test('совпадения после обрезки разводятся, а не затирают друг друга', () {
    // Обрезка сама создаёт совпадения: два длинных ФИО, совпадающие первыми
    // 31 знаками, дали бы один и тот же лист, и данные второго молча легли
    // бы к первому.
    final taken = <String>{};
    final a = excelSheetName('Каратаев Каиргельды Каиргельдыевич 1', taken);
    final b = excelSheetName('Каратаев Каиргельды Каиргельдыевич 2', taken);
    expect(a.length, lessThanOrEqualTo(31));
    expect(b.length, lessThanOrEqualTo(31));
    expect(a, isNot(b), reason: 'два листа слились бы в один');
  });

  test('одинаковые имена подряд получают разные листы', () {
    final taken = <String>{};
    final names = List.generate(5, (_) => excelSheetName('Иванов Иван', taken));
    expect(names.toSet().length, 5);
    for (final name in names) {
      expect(name.length, lessThanOrEqualTo(31));
    }
  });
}
