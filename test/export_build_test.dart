import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/functions/generate_csv.dart';
import 'package:se_mobile/functions/generate_excel.dart';

/// В выгрузке отдела проходы человека стоят под его фамилией.
///
/// Прежде фамилии брались из сохранённого списка, а проходы — из
/// загруженных на экране. После повторного входа на экран списки
/// расходились, и проходы одного ложились под фамилией другого.
void main() {
  const names = ['Тестов Аман', 'Пробная Бибігүл'];
  final data = [
    [
      ['2026-08-03', '08:01', 'Вход', 'Проходная 1'],
    ],
    [
      ['2026-08-04', '08:15', 'Вход', 'Проходная 2'],
      ['2026-08-04', '17:40', 'Выход', 'Проходная 2'],
    ],
  ];

  List<List<String>> rowsOf(Sheet sheet) => [
        for (final row in sheet.rows)
          [for (final cell in row) cell?.value?.toString() ?? ''],
      ];

  test('лист каждого — с его фамилией и его проходами', () {
    final book = Excel.decodeBytes(buildExcelEmp(names, data)!);
    final first = rowsOf(book.tables['Тестов Аман']!);
    expect(first.first.first, 'Тестов Аман');
    expect(first.skip(2).map((r) => r[3]), ['Проходная 1']);
    final second = rowsOf(book.tables['Пробная Бибігүл']!);
    expect(second.first.first, 'Пробная Бибігүл');
    expect(second.skip(2).map((r) => r[1]), ['08:15', '17:40']);
  });

  test('в общем листе за фамилией идут её проходы', () {
    final book = Excel.decodeBytes(buildExcelEmp(names, data)!);
    final all = rowsOf(book.tables['export_all_sheet']!);
    final second = all.indexWhere((r) => r.first == 'Пробная Бибігүл');
    expect(second, greaterThan(0));
    expect(all[second + 2][1], '08:15');
    expect(all.take(second).any((r) => r.contains('08:15')), isFalse);
  });

  test('в CSV за фамилией идут её проходы', () {
    final csv = buildCsvEmp(names, data);
    final lines = const LineSplitter().convert(csv);
    final second = lines.indexWhere((l) => l.startsWith('Пробная Бибігүл'));
    expect(lines[second + 2], contains('08:15'));
    expect(lines.take(second).any((l) => l.contains('08:15')), isFalse);
  });

  test('имён и отчётов поровну — иначе файла нет вовсе', () {
    expect(() => buildExcelEmp(names, data.take(1).toList()),
        throwsArgumentError);
    expect(() => buildCsvEmp(names.take(1).toList(), data),
        throwsArgumentError);
  });

  test('свой отчёт подписан тем, чьи это проходы', () {
    final book = Excel.decodeBytes(buildExcel('Тестов Аман', data.first)!);
    final sheet = rowsOf(book.tables['Тестов Аман']!);
    expect(sheet.first.first, 'Тестов Аман');
    expect(sheet.last[3], 'Проходная 1');
  });
}
