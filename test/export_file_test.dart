import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/functions/export_file.dart';

/// Выгрузки сравнивают между собой — «что было в июле, что в августе», — а
/// назывались они одинаково: `saved_report.xlsx`. Вторая затирала первую.
void main() {
  test('в имени файла есть и человек, и дата', () {
    final name = exportFileName('Иванов Иван Иванович', 'xlsx');
    expect(name.endsWith('.xlsx'), isTrue);
    expect(name.contains('Иванов'), isTrue);
    expect(name.contains(exportStamp()), isTrue);
  });

  test('две выгрузки подряд не затирают друг друга по имени человека', () {
    expect(exportFileName('Иванов', 'csv'),
        isNot(exportFileName('Петров', 'csv')));
  });

  test('разделители пути в имя файла не попадают', () {
    final name = exportFileName(r'Отдел/цех: "первый" *', 'csv');
    for (final bad in <String>['/', '\\', ':', '*', '?', '"', '<', '>', '|']) {
      expect(name.contains(bad), isFalse, reason: 'остался $bad');
    }
    expect(name.contains(' '), isFalse, reason: 'пробел в имени файла');
  });

  test('без имени файл всё равно называется', () {
    expect(fileSafe(null), 'report');
    expect(fileSafe(''), 'report');
    expect(fileSafe('   '), 'report');
  });

  test('буквы остаются буквами', () {
    // Имя файла читает человек: превращать «Тілеуғали» в подчёркивания
    // незачем.
    expect(fileSafe('Тілеуғали'), 'Тілеуғали');
  });

  test('метка UTF-8 — три байта, без которых Excel показывает кракозябры', () {
    expect(utf8Bom.codeUnits, <int>[0xFEFF]);
  });
}
