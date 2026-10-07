import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/requests/home_request.dart';

/// Сводка главного экрана: всё, чего сервер не знает, приходит null, и
/// разбор не должен на этом падать — иначе главный экран останется пустым у
/// всех, у кого нет, например, отпуска в выгрузке.
void main() {
  test('полная сводка', () {
    final s = HomeSummary.fromJson({
      'today': '2031-03-04',
      'access': {'date': '2031-02-27', 'first_in': '07:51', 'last_out': '17:05'},
      'payslip': {'year': 2031, 'month': 2},
      'leave': {'remaining_days': 26},
      'menu': {'count': 4, 'dishes': ['Борщ', 'Плов', 'Компот']},
    });
    expect(s.access!.date, DateTime(2031, 2, 27));
    expect(s.access!.firstIn, '07:51');
    expect(s.access!.lastOut, '17:05');
    expect(s.payslip, DateTime(2031, 2));
    expect(s.leaveDays, 26);
    expect(s.menuCount, 4);
    expect(s.dishes, ['Борщ', 'Плов', 'Компот']);
  });

  test('пустая сводка — без падения', () {
    final s = HomeSummary.fromJson({
      'access': null,
      'payslip': null,
      'leave': null,
      'menu': {'count': 0, 'dishes': []},
    });
    expect(s.access, isNull);
    expect(s.payslip, isNull);
    expect(s.leaveDays, isNull);
    expect(s.menuCount, 0);
    expect(s.dishes, isEmpty);
  });

  test('проход без выхода', () {
    final s = HomeSummary.fromJson({
      'access': {'date': '2031-03-04', 'first_in': '07:48', 'last_out': null},
    });
    expect(s.access!.firstIn, '07:48');
    expect(s.access!.lastOut, isNull);
  });
}
