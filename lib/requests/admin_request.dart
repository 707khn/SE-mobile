import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/variables.dart';
import '../utils/api.dart';
import '../utils/load_problem.dart';

/// One row of the staff directory shown in the admin panel.
class AdminEmployee {
  const AdminEmployee({
    required this.employeeId,
    required this.fullName,
    required this.jobTitle,
    required this.department,
    required this.iin,
    required this.login,
    required this.payslipCount,
    required this.accessCount,
    required this.leaveCount,
  });

  final String employeeId;
  final String fullName;
  final String jobTitle;
  final String department;
  final String iin;

  /// Empty when the person has no way to sign in to the app.
  final String login;

  final int payslipCount;
  final int accessCount;
  final int leaveCount;

  bool get hasLogin => login.isNotEmpty;

  factory AdminEmployee.fromJson(Map<String, dynamic> json) => AdminEmployee(
        employeeId: (json['employee_id'] as String?) ?? '',
        fullName: (json['full_name'] as String?) ?? '',
        jobTitle: (json['job_title'] as String?) ?? '',
        department: (json['department'] as String?) ?? '',
        iin: (json['iin'] as String?) ?? '',
        login: (json['login'] as String?) ?? '',
        payslipCount: (json['payslip_count'] as num?)?.toInt() ?? 0,
        accessCount: (json['access_count'] as num?)?.toInt() ?? 0,
        leaveCount: (json['leave_count'] as num?)?.toInt() ?? 0,
      );
}

/// Returns every employee on record. Throws on failure so the screen can tell
/// an empty company apart from an unreachable server.
Future<List<AdminEmployee>> fetchAllEmployees() async {
  final response = await http
      .get(
        Uri.parse('${AppValues.baseUrl}/api/admin/employees'),
        headers: await authHeaders(),
      )
      .timeout(const Duration(seconds: 30));

  if (await handledUnauthorized(response)) return const <AdminEmployee>[];
  if (response.statusCode != 200) {
    throw LoadFailure(problemForStatus(response.statusCode),
        'HTTP ${response.statusCode}');
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final rows = (body['employees'] as List<dynamic>?) ?? [];
  return rows
      .map((e) => AdminEmployee.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// Готовность к включению обязательной проверки пропуска.
///
/// Один вопрос: дошла ли новая сборка до всех. Пока приходят запросы без
/// пропуска, включать нельзя — у необновившихся приложение перестанет
/// работать в ту же минуту.
class RolloutReport {
  RolloutReport({
    required this.requireAuth,
    required this.accounts,
    required this.byVersion,
    required this.notSeenForAWeek,
    required this.withoutPass,
    required this.inCodePasswords,
  });

  final bool requireAuth;
  final int accounts;
  final Map<String, int> byVersion;
  final int notSeenForAWeek;

  /// По дням, свежие сверху: сколько запросов пришло без пропуска.
  final List<MapEntry<String, int>> withoutPass;

  /// По дням: сколько раз вход не нашёл своей строки в user_accounts.
  /// Пока это ноль, всё в порядке; не ноль — учётка пропала из базы.
  final List<MapEntry<String, int>> inCodePasswords;

  /// Сколько учётных записей всё ещё с выданным паролем — табельным номером.
  int temporaryPasswords = 0;

  /// По какое число заполнен каждый источник данных.
  List<DataSource> data = <DataSource>[];

  /// Сборка, лежащая на сервере для скачивания: «1.8.2 (12)» или пусто.
  String appOnServer = '';

  /// Почему её нет.
  String appProblem = '';

  /// Почему новые сборки не приезжают из GitHub Releases сами: истёк токен,
  /// таймер не запускается. Пусто — приезжают.
  String fetchProblem = '';

  /// Последние перебои, замеченные сторожем на сервере. Пусто — не падал.
  List<Outage> outages = <Outage>[];

  /// Сколько записей в журнале сторожа всего.
  int outageTotal = 0;

  /// Копии базы: сколько дней назад делалась последняя и сколько их всего.
  /// null в [backupDaysAgo] — копий нет или папка недоступна.
  int? backupDaysAgo;
  int backupCount = 0;
  String backupProblem = '';

  /// Сколько копий лежит во внешнем хранилище — на случай, если сервер умрёт
  /// вместе со своими копиями.
  int offsiteCount = 0;

  /// Почему копии не уезжают с сервера. Пусто — уезжают.
  String offsiteProblem = '';

  /// Сколько дней назад из копии пробовали восстановиться. null — ни разу.
  int? restoreTestDaysAgo;

  /// Что не так с пробным восстановлением: не было, не удалось, давно.
  String restoreTestProblem = '';
}

List<MapEntry<String, int>> _days(dynamic raw) {
  if (raw is! List) return <MapEntry<String, int>>[];
  return raw
      .whereType<Map>()
      .map((d) => MapEntry((d['day'] as String?) ?? '',
          (d['count'] as num?)?.toInt() ?? 0))
      .toList();
}

Future<RolloutReport> fetchRollout() async {
  final response = await http
      .get(Uri.parse('${AppValues.baseUrl}/api/admin/rollout'),
          headers: await authHeaders())
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw LoadFailure(problemForStatus(response.statusCode),
        'HTTP ${response.statusCode}');
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final versions = (body['by_version'] as Map?) ?? {};
  final backups = (body['backups'] as Map?) ?? {};
  final report = RolloutReport(
    requireAuth: body['require_auth'] == true,
    accounts: (body['accounts'] as num?)?.toInt() ?? 0,
    byVersion: versions.map((key, value) =>
        MapEntry(key.toString(), (value as num?)?.toInt() ?? 0)),
    notSeenForAWeek: (body['not_seen_for_a_week'] as num?)?.toInt() ?? 0,
    withoutPass: _days(body['without_pass']),
    inCodePasswords: _days(body['in_code_passwords']),
  );
  report.temporaryPasswords =
      (body['temporary_passwords'] as num?)?.toInt() ?? 0;
  report.data = _dataSources(body['data']);
  final outages = (body['outages'] as Map?) ?? {};
  report.outageTotal = (outages['total'] as num?)?.toInt() ?? 0;
  report.outages = ((outages['entries'] as List?) ?? [])
      .whereType<Map>()
      .map((e) => Outage(
            at: DateTime.tryParse((e['at'] as String?) ?? ''),
            what: (e['what'] as String?) ?? '',
          ))
      .toList();
  final app = (body['app'] as Map?) ?? {};
  if (app['available'] == true) {
    report.appOnServer = '${app['version']} (${app['build']})';
  } else {
    report.appProblem = (app['reason'] as String?) ?? '';
  }
  final fetch = (body['fetch_apk'] as Map?) ?? {};
  report.fetchProblem = (fetch['problem'] as String?) ?? '';
  report.backupCount = (backups['count'] as num?)?.toInt() ?? 0;
  report.backupDaysAgo = (backups['days_ago'] as num?)?.toInt();
  report.backupProblem =
      backups['available'] == false ? ((backups['reason'] as String?) ?? '') : '';
  final offsite = (body['offsite'] as Map?) ?? {};
  report.offsiteCount = (offsite['count'] as num?)?.toInt() ?? 0;
  report.offsiteProblem = (offsite['problem'] as String?) ?? '';
  final restore = (body['restore_test'] as Map?) ?? {};
  report.restoreTestDaysAgo = (restore['days_ago'] as num?)?.toInt();
  report.restoreTestProblem = (restore['problem'] as String?) ?? '';
  return report;
}

/// Свежесть одного источника данных: листки, проходы, меню, новости.
///
/// Всё, что ломалось в приложении на глазах у сотрудников, ломалось
/// одинаково: данные отставали, а видел это только тот, кто открыл экран и
/// увидел пустоту. Здесь то же самое видит тот, кто может загрузить новые.
class DataSource {
  const DataSource({
    required this.key,
    required this.last,
    required this.daysBehind,
    required this.rows,
    required this.people,
    required this.note,
  });

  /// payslips, access, menu, news, leaves, directory, employees.
  final String key;

  /// По какое число заполнено. null — у источника нет даты (справочник) или
  /// он пуст.
  final DateTime? last;

  /// Сколько дней назад это было.
  final int? daysBehind;

  final int rows;

  /// Скольких людей покрывает последняя выгрузка. null — не считается.
  final int? people;

  /// Почему не удалось посчитать.
  final String note;
}

List<DataSource> _dataSources(dynamic raw) {
  if (raw is! List) return <DataSource>[];
  return raw.whereType<Map>().map((d) {
    final last = d['last'];
    return DataSource(
      key: (d['key'] as String?) ?? '',
      last: last is String && last.isNotEmpty ? DateTime.tryParse(last) : null,
      daysBehind: (d['days_behind'] as num?)?.toInt(),
      rows: (d['rows'] as num?)?.toInt() ?? 0,
      people: (d['people'] as num?)?.toInt(),
      note: (d['note'] as String?) ?? '',
    );
  }).toList();
}

/// Перебой, записанный сторожем на сервере.
///
/// Сбой 12 сентября прожил восемь дней, и узнали о нём от сотрудника.
/// Сторож теперь поднимает упавшее сам, но заметить мало — надо, чтобы это
/// увидел человек.
class Outage {
  const Outage({required this.at, required this.what});

  final DateTime? at;
  final String what;
}
