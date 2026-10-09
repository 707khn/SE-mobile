import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/functions/export_file.dart';

/// Выгрузки сравнивают между собой — «что было в июле, что в августе», — а
/// назывались они одинаково: `saved_report.xlsx`. Вторая затирала первую.
void main() {
  test('в имени файла есть и человек, и дата', () {
    final at = DateTime(2026, 7, 31, 9, 5, 7);
    final name = exportFileName('Иванов Иван Иванович', 'xlsx', at: at);
    expect(name, 'Иванов_Иван_Иванович_2026-07-31_090507.xlsx');
  });

  test('две выгрузки в одну минуту не затирают друг друга', () {
    // Июль, смена дат, август — меньше чем за минуту.
    expect(exportFileName('report', 'xlsx', at: DateTime(2026, 8, 1, 9, 5, 7)),
        isNot(exportFileName('report', 'xlsx',
            at: DateTime(2026, 8, 1, 9, 5, 40))));
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

  group('выгрузки на телефоне', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('exports-'));
    tearDown(() => dir.deleteSync(recursive: true));

    DateTime minute(int n) => DateTime(2026, 8, 1, 9, 0, 0).add(
        Duration(minutes: n));

    test('«последний файл» — тот, что выгружен последним', () async {
      expect(latestExport(dir, 'Иванов', 'xlsx'), isNull);
      await saveExport(dir, 'Иванов', 'xlsx', [1], at: minute(1));
      final last =
          await saveExport(dir, 'Иванов', 'xlsx', [2], at: minute(2));
      expect(latestExport(dir, 'Иванов', 'xlsx')!.path, last.path);
      expect(latestExport(dir, 'Иванов', 'xlsx')!.readAsBytesSync(), [2]);
    });

    test('свой отчёт и отчёт отдела, Excel и CSV — порознь', () async {
      final own = await saveExport(dir, 'Иванов', 'xlsx', [1], at: minute(1));
      final team = await saveExport(dir, 'report', 'xlsx', [2], at: minute(2));
      final csv = await saveExport(dir, 'Иванов', 'csv', [3], at: minute(3));
      expect(latestExport(dir, 'Иванов', 'xlsx')!.path, own.path);
      expect(latestExport(dir, 'report', 'xlsx')!.path, team.path);
      expect(latestExport(dir, 'Иванов', 'csv')!.path, csv.path);
      // Другой человек с той же фамилией в начале — не тот же.
      await saveExport(dir, 'Иванов Пётр', 'xlsx', [4], at: minute(4));
      expect(latestExport(dir, 'Иванов', 'xlsx')!.path, own.path);
    });

    test('прежние выгрузки, без секунд в имени, тоже находятся', () async {
      File('${dir.path}/report_2026-08-01_0930.xlsx').writeAsBytesSync([1]);
      expect(latestExport(dir, 'report', 'xlsx')!.path,
          endsWith('report_2026-08-01_0930.xlsx'));
      // Новая, сделанная минутой раньше по часам, — всё же раньше.
      await saveExport(dir, 'report', 'xlsx', [2],
          at: DateTime(2026, 8, 1, 9, 29, 59));
      expect(latestExport(dir, 'report', 'xlsx')!.path,
          endsWith('report_2026-08-01_0930.xlsx'));
      final newer = await saveExport(dir, 'report', 'xlsx', [3],
          at: DateTime(2026, 8, 1, 9, 30, 1));
      expect(latestExport(dir, 'report', 'xlsx')!.path, newer.path);
    });

    test('хранится не больше $keepExports выгрузок одного вида', () async {
      for (var i = 0; i < keepExports + 5; i++) {
        await saveExport(dir, 'report', 'xlsx', [i], at: minute(i));
      }
      await saveExport(dir, 'Иванов', 'xlsx', [0], at: minute(0));
      final left = dir.listSync().whereType<File>().map((f) => f.path).toList();
      expect(left.where((p) => p.contains('report_')).length, keepExports);
      // Убраны самые старые, а чужого вида не тронуто.
      expect(left.any((p) => p.endsWith(exportFileName(
          'report', 'xlsx', at: minute(0)))), isFalse);
      expect(latestExport(dir, 'report', 'xlsx')!.readAsBytesSync(),
          [keepExports + 4]);
      expect(latestExport(dir, 'Иванов', 'xlsx'), isNotNull);
    });

    test('при выходе выгрузки стираются, остальное — нет', () async {
      await saveExport(dir, 'Иванов', 'xlsx', [1], at: minute(1));
      await saveExport(dir, 'report', 'csv', [2], at: minute(2));
      File('${dir.path}/saved_report.xlsx').writeAsBytesSync([3]);
      final other = File('${dir.path}/notes.txt')..writeAsStringSync('x');
      await clearExports(dir);
      expect(dir.listSync().map((e) => e.path), [other.path]);
    });

    test('папки нет — стирать нечего, и это не ошибка', () async {
      await clearExports(Directory('${dir.path}/нет'));
      expect(latestExport(Directory('${dir.path}/нет'), 'report', 'xlsx'),
          isNull);
    });
  });
}
