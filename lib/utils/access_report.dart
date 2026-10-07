import 'load_problem.dart';

/// Проходы турникета вместе с объяснением, почему их может не быть.
///
/// Пустой список на этом экране раньше значил что угодно: нет связи, нет
/// человека в выгрузке СКУД, нет проходов в выбранные дни. Экран во всех
/// случаях говорил одно и то же — «нет данных, выберите период», — и
/// предлагал выбрать период человеку, у которого проходов нет вовсе.
///
/// Разница между этими случаями известна серверу, и теперь он её сообщает.
class AccessCoverage {
  const AccessCoverage({
    required this.loadedUntil,
    required this.employeeUntil,
    required this.employeeHasAny,
  });

  /// По какое число проходы загружены по всему предприятию.
  final DateTime? loadedUntil;

  /// Последний проход этого сотрудника.
  final DateTime? employeeUntil;

  /// Есть ли у него хоть один проход.
  final bool employeeHasAny;

  static AccessCoverage? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    return AccessCoverage(
      loadedUntil: _date(raw['loaded_until']),
      employeeUntil: _date(raw['employee_until']),
      employeeHasAny: raw['employee_has_any'] == true,
    );
  }

  static DateTime? _date(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }

  /// Отстают ли данные от сегодняшнего дня — и насколько.
  ///
  /// Выгрузку из СКУД приносят раз в месяц, поэтому «сегодня» в отчёте не
  /// бывает почти никогда. Сказать об этом дешевле, чем каждый раз отвечать
  /// на вопрос, почему сегодняшнего прохода не видно.
  int? get daysBehind {
    final until = loadedUntil;
    if (until == null) return null;
    final today = DateTime.now();
    return DateTime(today.year, today.month, today.day)
        .difference(DateTime(until.year, until.month, until.day))
        .inDays;
  }

  /// Позже ли выбранный день последней выгрузки.
  bool isBeyondData(DateTime day) {
    final until = loadedUntil;
    if (until == null) return false;
    return DateTime(day.year, day.month, day.day)
        .isAfter(DateTime(until.year, until.month, until.day));
  }
}

/// Ответ на запрос проходов: сами записи и то, чем объяснить их отсутствие.
class AccessReport {
  const AccessReport(this.entries, this.coverage,
      {this.problem, this.cachedAt});

  /// Как и раньше: дата, время, событие, точка прохода.
  final List<List<String>> entries;

  /// null у старого сервера — тогда экран ведёт себя по-прежнему.
  final AccessCoverage? coverage;

  /// Почему ответа нет — только у неудачного.
  final LoadProblem? problem;

  /// Показана сохранённая копия: когда её получили с сервера.
  final DateTime? cachedAt;

  static const AccessReport empty = AccessReport(<List<String>>[], null);

  /// Ответ не получен вовсе: связь, тайм-аут, отказ сервера.
  static final AccessReport failed = AccessReport([
    <String>['no']
  ], null);

  /// То же, с причиной: экран скажет «нет связи» или «сервер ответил
  /// ошибкой», а не одно общее «не удалось загрузить».
  static AccessReport failedWith(LoadProblem problem) => AccessReport([
        <String>['no']
      ], null, problem: problem);

  bool get isFailure =>
      entries.length == 1 && entries[0].isNotEmpty && entries[0][0] == 'no';
}
