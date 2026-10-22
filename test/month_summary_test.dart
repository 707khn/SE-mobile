import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/load_problem.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/month_summary.dart';
import 'package:se_mobile/widgets/load_error_view.dart';
import 'package:se_mobile/widgets/month_summary_card.dart';

/// Итоги месяца по своим проходам: разбор ответа и карточка над списком.
void main() {
  Map<String, dynamic> answer(String month) => {
        'message': 'Success',
        'month': month,
        'work_start': '08:00',
        'days_present': 3,
        'weekend_days': 1,
        'avg_arrival': '08:10',
        'avg_departure': '17:05',
        'late_count': 1,
        'first_month': '2025-01',
        'days': [
          {'date': '$month-03', 'first_in': '07:50', 'last_out': '17:10',
           'late': false, 'weekend': false},
          {'date': '$month-04', 'first_in': '08:20', 'last_out': '17:00',
           'late': true, 'weekend': false},
          {'date': '$month-08', 'first_in': '10:30', 'last_out': null,
           'late': false, 'weekend': true},
        ],
        'coverage': {'loaded_until': '2099-01-01', 'employee_until': '2099-01-01',
                     'employee_has_any': true},
      };

  test('разбор ответа', () {
    final s = MonthSummary.fromJson(answer('2025-03'))!;
    expect(s.month, DateTime(2025, 3));
    expect(s.daysPresent, 3);
    expect(s.avgArrival, '08:10');
    expect(s.lateDays.single.date, DateTime(2025, 3, 4));
    expect(s.firstMonth, DateTime(2025, 1));
    expect(s.partial, isFalse);
  });

  test('месяц позже выгрузки — «ещё не загружены», а не «не приходил»', () {
    final s = MonthSummary.fromJson({
      'month': '2025-05',
      'days_present': 0,
      'days': [],
      'coverage': {'loaded_until': '2025-04-20', 'employee_has_any': true},
    })!;
    expect(s.isEmpty, isTrue);
    expect(s.notLoadedYet, isTrue);
  });

  test('выгрузка обрывается внутри месяца — итог неполный', () {
    final s = MonthSummary.fromJson({
      'month': '2025-04',
      'days_present': 2,
      'days': [],
      'coverage': {'loaded_until': '2025-04-20', 'employee_has_any': true},
    })!;
    expect(s.partial, isTrue);
  });

  test('кривой месяц не разбирается', () {
    expect(MonthSummary.fromJson({'month': '2025-13'}), isNull);
    expect(parseMonth('2025-3'), isNull);
    expect(monthKey(DateTime(2025, 3)), '2025-03');
    expect(previousMonth(DateTime(2025, 1)), DateTime(2024, 12));
  });

  Future<void> open(WidgetTester tester,
      Future<MonthSummary?> Function(DateTime) load) async {
    await tester.runAsync(Lang.initDates);
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: Scaffold(body: SingleChildScrollView(child: MonthSummaryCard(load: load))),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('итоги и переключение месяца', (tester) async {
    final asked = <DateTime>[];
    await open(tester, (m) async {
      asked.add(m);
      return MonthSummary.fromJson(answer(monthKey(m)));
    });
    final now = DateTime.now();
    expect(asked, [DateTime(now.year, now.month)]);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('08:10'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);

    // Вперёд из текущего месяца нельзя, назад — можно.
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(asked.length, 1);
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(asked.last, DateTime(now.year, now.month - 1));

    // По нажатию на опоздания — их дни.
    expect(find.text('08:20'), findsNothing);
    await tester.tap(find.text('month_late'.tr));
    await tester.pumpAndSettle();
    expect(find.text('08:20'), findsOneWidget);
  });

  testWidgets('не загрузилось — причина и повтор', (tester) async {
    await open(tester, (m) async => throw const LoadFailure(LoadProblem.offline));
    expect(find.byType(LoadErrorView), findsOneWidget);
  });

  testWidgets('старый сервер итогов не знает — карточки нет', (tester) async {
    await open(tester, (m) async => null);
    expect(find.text('month_summary'.tr), findsNothing);
  });
}
