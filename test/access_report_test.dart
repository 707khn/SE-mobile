import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/access_report.dart';

/// Пустой список проходов значил что угодно: нет связи, человека нет в
/// выгрузке СКУД, в эти дни не проходил. Экран на все три отвечал «нет данных,
/// выберите период» — и предлагал выбрать период тому, у кого проходов нет
/// вовсе. Разницу знает сервер; здесь проверяется, что приложение её не теряет.
void main() {
  group('AccessCoverage', () {
    test('читает ответ сервера', () {
      final coverage = AccessCoverage.fromJson({
        'loaded_until': '2026-08-20',
        'employee_until': '2026-08-19',
        'employee_has_any': true,
      });
      expect(coverage, isNotNull);
      expect(coverage!.loadedUntil, DateTime(2026, 8, 20));
      expect(coverage.employeeUntil, DateTime(2026, 8, 19));
      expect(coverage.employeeHasAny, isTrue);
    });

    test('старый сервер не присылает ничего — и это не поломка', () {
      expect(AccessCoverage.fromJson(null), isNull);
      expect(AccessCoverage.fromJson('что-то не то'), isNull);
    });

    test('человека нет в выгрузке вовсе', () {
      final coverage = AccessCoverage.fromJson({
        'loaded_until': '2026-08-20',
        'employee_until': null,
        'employee_has_any': false,
      })!;
      expect(coverage.employeeHasAny, isFalse);
      expect(coverage.employeeUntil, isNull);
    });

    test('день позже последней выгрузки', () {
      final coverage = AccessCoverage.fromJson({
        'loaded_until': '2026-08-20',
        'employee_until': '2026-08-20',
        'employee_has_any': true,
      })!;
      // Сентябрь позже 20 августа — «данные ещё не загружены».
      expect(coverage.isBeyondData(DateTime(2026, 9, 1)), isTrue);
      // Сам день выгрузки и всё до него — уже «не проходил».
      expect(coverage.isBeyondData(DateTime(2026, 8, 20)), isFalse);
      expect(coverage.isBeyondData(DateTime(2026, 8, 19)), isFalse);
      // Время внутри дня роли не играет: сравниваются даты.
      expect(coverage.isBeyondData(DateTime(2026, 8, 20, 23, 59)), isFalse);
    });

    test('без даты загрузки ничего не утверждаем', () {
      final coverage = AccessCoverage.fromJson({
        'loaded_until': null,
        'employee_until': null,
        'employee_has_any': false,
      })!;
      expect(coverage.isBeyondData(DateTime(2099, 1, 1)), isFalse);
      expect(coverage.daysBehind, isNull);
    });

    test('отставание считается в днях', () {
      final today = DateTime.now();
      final coverage = AccessCoverage(
        loadedUntil: DateTime(today.year, today.month, today.day)
            .subtract(const Duration(days: 34)),
        employeeUntil: null,
        employeeHasAny: true,
      );
      expect(coverage.daysBehind, 34);
    });
  });

  group('AccessReport', () {
    test('пустой список — это ответ, а не отказ', () {
      expect(AccessReport.empty.isFailure, isFalse);
      expect(AccessReport.empty.entries, isEmpty);
    });

    test('отказ отличим от пустоты', () {
      expect(AccessReport.failed.isFailure, isTrue);
    });

    test('заполненный отчёт отказом не считается', () {
      const report = AccessReport(<List<String>>[
        <String>['01.08.2026', '07:40', 'Вход', 'Проходная'],
      ], null);
      expect(report.isFailure, isFalse);
    });
  });
}
