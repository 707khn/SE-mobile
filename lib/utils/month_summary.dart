import 'access_report.dart';

/// Один день месяца: когда пришёл, когда ушёл, опоздал ли.
class MonthDay {
  const MonthDay({
    required this.date,
    this.firstIn,
    this.lastOut,
    this.late = false,
    this.weekend = false,
  });

  final DateTime date;
  final String? firstIn;
  final String? lastOut;
  final bool late;
  final bool weekend;
}

/// Итоги месяца по своим проходам — то, что раньше человек считал сам по
/// списку: сколько дней был на работе, во сколько в среднем приходил,
/// сколько раз опоздал.
///
/// Считает сервер: у него и выгрузка СКУД, и сегодняшние события турникета,
/// которых в выгрузке ещё нет.
class MonthSummary {
  const MonthSummary({
    required this.month,
    required this.workStart,
    required this.daysPresent,
    required this.weekendDays,
    required this.lateCount,
    required this.days,
    this.avgArrival,
    this.avgDeparture,
    this.firstMonth,
    this.coverage,
  });

  /// Первое число месяца.
  final DateTime month;

  /// С какого времени приход считается опозданием, «08:00».
  final String workStart;
  final int daysPresent;
  final int weekendDays;
  final int lateCount;
  final String? avgArrival;
  final String? avgDeparture;
  final List<MonthDay> days;

  /// Самый ранний месяц с проходами — назад дальше листать незачем.
  final DateTime? firstMonth;
  final AccessCoverage? coverage;

  List<MonthDay> get lateDays => days.where((d) => d.late).toList();

  bool get isEmpty => daysPresent == 0;

  /// Месяц целиком позже последней выгрузки: пусто не потому, что не
  /// приходил, а потому, что проходы ещё не загрузили.
  bool get notLoadedYet {
    final until = coverage?.loadedUntil;
    return until != null && isEmpty && month.isAfter(until);
  }

  /// Выгрузка обрывается внутри месяца: итог пока неполный.
  bool get partial {
    final until = coverage?.loadedUntil;
    if (until == null) return false;
    final next = nextMonth(month);
    return !until.isBefore(month) && until.isBefore(next.subtract(const Duration(days: 1)));
  }

  static MonthSummary? fromJson(Map<String, dynamic> body) {
    final month = parseMonth(body['month']);
    if (month == null) return null;
    final days = <MonthDay>[];
    for (final raw in (body['days'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final date = DateTime.tryParse('${raw['date']}');
      if (date == null) continue;
      days.add(MonthDay(
        date: date,
        firstIn: raw['first_in'] as String?,
        lastOut: raw['last_out'] as String?,
        late: raw['late'] == true,
        weekend: raw['weekend'] == true,
      ));
    }
    int number(dynamic v) => v is num ? v.toInt() : 0;
    return MonthSummary(
      month: month,
      workStart: (body['work_start'] as String?) ?? '08:00',
      daysPresent: number(body['days_present']),
      weekendDays: number(body['weekend_days']),
      lateCount: number(body['late_count']),
      avgArrival: body['avg_arrival'] as String?,
      avgDeparture: body['avg_departure'] as String?,
      days: days,
      firstMonth: parseMonth(body['first_month']),
      coverage: AccessCoverage.fromJson(body['coverage']),
    );
  }
}

/// «2026-09» → 1 сентября 2026; что угодно другое — null.
DateTime? parseMonth(dynamic value) {
  if (value is! String) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(value);
  if (m == null) return null;
  final month = int.parse(m.group(2)!);
  if (month < 1 || month > 12) return null;
  return DateTime(int.parse(m.group(1)!), month);
}

/// 1 сентября 2026 → «2026-09».
String monthKey(DateTime month) =>
    '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}';

DateTime nextMonth(DateTime month) => DateTime(month.year, month.month + 1);

DateTime previousMonth(DateTime month) => DateTime(month.year, month.month - 1);
