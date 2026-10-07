import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/access_cache.dart';

/// Копия проходов на телефоне. Неполная копия опаснее пустой: проход,
/// которого в ней нет, выглядит как «в этот день не проходил».
void main() {
  Map<String, dynamic> pass(String date, String time, [String event = 'Вход']) =>
      {'date': date, 'time': time, 'event': event, 'door': 'Проходная'};

  final coverage = {
    'loaded_until': '2026-09-30',
    'employee_until': '2026-09-30',
    'employee_has_any': true,
  };

  test('полный отчёт отвечает и целиком, и за любой период', () {
    final saved = AccessCache.full({
      'report': [pass('2026-09-01', '07:50'), pass('2026-09-15', '07:45')],
      'coverage': coverage,
    });

    expect(AccessCache.answer(saved)!.entries.length, 2);
    final sept = AccessCache.answer(saved, from: '2026-09-10', to: '2026-09-20')!;
    expect(sept.entries.map((e) => e[0]), ['2026-09-15']);
    expect(sept.coverage!.employeeHasAny, isTrue);
  });

  test('без копии и без загруженного периода — ничего, а не пустота', () {
    expect(AccessCache.answer(null), isNull);

    final week = AccessCache.merge(null, {
      'report': [pass('2026-09-22', '07:50')],
      'coverage': coverage,
    }, '2026-09-22', '2026-09-28');

    // Этот период загружали — отвечаем.
    expect(AccessCache.answer(week, from: '2026-09-22', to: '2026-09-28')!
        .entries.length, 1);
    // Часть его — тоже.
    expect(AccessCache.answer(week, from: '2026-09-23', to: '2026-09-24')!
        .entries, isEmpty);
    // Шире загруженного — нет: дни вне его выглядели бы днями без проходов.
    expect(AccessCache.answer(week, from: '2026-09-01', to: '2026-09-28'), isNull);
    // Целиком — тоже нет.
    expect(AccessCache.answer(week), isNull);
  });

  test('новый ответ за период заменяет старые записи этих дней', () {
    final saved = AccessCache.full({
      'report': [
        pass('2026-09-01', '07:50'),
        pass('2026-09-15', '07:45'),
        pass('2026-09-15', '17:00', 'Выход'),
      ],
      'coverage': coverage,
    });
    final merged = AccessCache.merge(saved, {
      'report': [pass('2026-09-15', '07:40')],
      'coverage': coverage,
    }, '2026-09-15', '2026-09-15');

    final all = AccessCache.answer(merged)!.entries;
    expect(all.map((e) => '${e[0]} ${e[1]}'),
        ['2026-09-01 07:50', '2026-09-15 07:40']);
  });

  test('периодов помнит не больше двадцати', () {
    Map<String, dynamic>? saved;
    for (var d = 1; d <= 25; d++) {
      final day = '2026-08-${d.toString().padLeft(2, '0')}';
      saved = AccessCache.merge(saved, {'report': [pass(day, '07:50')]}, day, day);
    }
    expect((saved!['ranges'] as List).length, 20);
    expect(AccessCache.answer(saved, from: '2026-08-25', to: '2026-08-25'),
        isNotNull);
    expect(AccessCache.answer(saved, from: '2026-08-01', to: '2026-08-01'),
        isNull);
  });
}
