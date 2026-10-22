import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

/// Заявка в отдел кадров: справка с места работы, о доходах или заявление
/// на отпуск.
class HrRequest {
  final int id;
  final String kind;
  final String details;
  final int copies;
  final String leaveType;
  final DateTime? startDate;
  final DateTime? endDate;

  /// new, accepted, ready, done, rejected, cancelled.
  final String status;

  /// Что сказали кадры: где забрать готовую, почему отказ.
  final String hrNote;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Только в очереди у кадров: чья заявка.
  final String employeeName;
  final String employeeJob;
  final String employeeDepartment;
  final String employeeId;

  const HrRequest({
    required this.id,
    required this.kind,
    this.details = '',
    this.copies = 1,
    this.leaveType = '',
    this.startDate,
    this.endDate,
    required this.status,
    this.hrNote = '',
    this.createdAt,
    this.updatedAt,
    this.employeeName = '',
    this.employeeJob = '',
    this.employeeDepartment = '',
    this.employeeId = '',
  });

  static HrRequest fromJson(Map<String, dynamic> j) {
    final who = j['employee'] is Map ? j['employee'] as Map : const {};
    DateTime? day(Object? v) => v is String ? DateTime.tryParse(v) : null;
    return HrRequest(
      id: (j['id'] as num).toInt(),
      kind: '${j['kind'] ?? ''}',
      details: '${j['details'] ?? ''}',
      copies: (j['copies'] as num?)?.toInt() ?? 1,
      leaveType: '${j['leave_type'] ?? ''}',
      startDate: day(j['start_date']),
      endDate: day(j['end_date']),
      status: '${j['status'] ?? 'new'}',
      hrNote: '${j['hr_note'] ?? ''}',
      createdAt: day(j['created_at']),
      updatedAt: day(j['updated_at']),
      employeeName: '${who['full_name'] ?? ''}',
      employeeJob: '${who['job_title'] ?? ''}',
      employeeDepartment: '${who['department'] ?? ''}',
      employeeId: '${who['employee_id'] ?? ''}',
    );
  }

  bool get isOpen => const {'new', 'accepted', 'ready'}.contains(status);

  /// Отозвать можно, пока кадры не взяли её в работу.
  bool get canCancel => status == 'new';

  /// Календарных дней отпуска, включая оба края.
  int get vacationDays => startDate == null || endDate == null
      ? 0
      : endDate!.difference(startDate!).inDays + 1;

  /// Что кадры могут сделать с заявкой дальше. Порядок — как на кнопках.
  List<String> get nextSteps => switch (status) {
        'new' => const ['accepted', 'ready', 'rejected'],
        'accepted' => const ['ready', 'rejected'],
        'ready' => const ['done', 'rejected'],
        _ => const [],
      };
}

/// Ключи надписей по виду заявки и по состоянию.
String hrKindKey(String kind) => 'hr_kind_$kind';
String hrStatusKey(String status) => 'hr_status_$status';

/// Ответ сервера списком заявок — или причина, почему его нет.
class HrList {
  final List<HrRequest> items;
  final Map<String, int> counts;
  final LoadProblem? problem;

  const HrList(this.items, {this.counts = const {}, this.problem});

  bool get failed => problem != null;
}

Future<HrList> _getList(String path) async {
  try {
    final response = await http
        .get(Uri.parse('${AppValues.baseUrl}$path'), headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const HrList([], problem: LoadProblem.server);
    }
    if (response.statusCode != 200) {
      return HrList(const [], problem: problemForStatus(response.statusCode));
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final counts = <String, int>{};
    if (body['counts'] is Map) {
      (body['counts'] as Map).forEach((k, v) {
        if (v is num) counts['$k'] = v.toInt();
      });
    }
    return HrList(
      [
        for (final item in (body['items'] as List? ?? const []))
          HrRequest.fromJson(item as Map<String, dynamic>),
      ],
      counts: counts,
    );
  } catch (e) {
    return HrList(const [], problem: problemOf(e));
  }
}

/// Свои заявки, свежие первыми.
Future<HrList> getMyHrRequests() => _getList('/api/hr/requests');

/// Очередь для кадров. [status]: open (по умолчанию), new, accepted, ready, all.
Future<HrList> getHrQueue({String status = 'open'}) =>
    _getList('/api/hr/queue?status=$status');

/// Чем кончилась отправка: заявка — удалось; иначе код ошибки сервера или
/// «network», если до него не дошли.
class HrResult {
  final HrRequest? item;
  final String? error;
  const HrResult({this.item, this.error});
  bool get ok => item != null;
}

Future<HrResult> _post(String path, Map<String, dynamic> body) async {
  try {
    final response = await http
        .post(Uri.parse('${AppValues.baseUrl}$path'),
            headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const HrResult(error: 'unauthorized');
    }
    Map<String, dynamic>? decoded;
    try {
      decoded = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}
    if (response.statusCode == 200 && decoded?['item'] is Map) {
      return HrResult(
          item: HrRequest.fromJson(decoded!['item'] as Map<String, dynamic>));
    }
    return HrResult(error: '${decoded?['error'] ?? 'server'}');
  } catch (_) {
    return const HrResult(error: 'network');
  }
}

String _isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Подать заявку.
Future<HrResult> createHrRequest({
  required String kind,
  String details = '',
  int copies = 1,
  String? leaveType,
  DateTime? startDate,
  DateTime? endDate,
}) =>
    _post('/api/hr/requests', {
      'kind': kind,
      'details': details,
      'copies': copies,
      if (leaveType != null) 'leave_type': leaveType,
      if (startDate != null) 'start_date': _isoDay(startDate),
      if (endDate != null) 'end_date': _isoDay(endDate),
    });

/// Отозвать свою, ещё не принятую.
Future<HrResult> cancelHrRequest(int id) =>
    _post('/api/hr/requests/$id/cancel', const {});

/// Кадры: перевести заявку в [status] с пометкой для сотрудника.
Future<HrResult> setHrRequestStatus(int id, String status, {String note = ''}) =>
    _post('/api/hr/requests/$id', {'status': status, 'note': note});
