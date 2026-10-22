import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/iso_day.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'assignment_request.dart' show AssignPerson;

const medicalExamKinds = ['periodic', 'fluorography', 'vaccination'];
const medicalSlotKinds = ['exam', 'vaccination', 'consult'];

DateTime? _day(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

AssignPerson? _person(Object? raw) =>
    raw is Map ? AssignPerson.fromJson(Map<String, dynamic>.from(raw)) : null;

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) =>
    ((raw as List?) ?? const [])
        .whereType<Map>()
        .map((e) => parse(Map<String, dynamic>.from(e)))
        .toList();

/// Срок осмотра: [state] — ok, soon или overdue.
class MedicalExam {
  const MedicalExam(
      {required this.id,
      required this.kind,
      this.dueOn,
      this.lastDoneOn,
      this.state = 'ok',
      this.employee});

  final int id;
  final String kind;
  final DateTime? dueOn;
  final DateTime? lastDoneOn;
  final String state;
  final AssignPerson? employee;

  factory MedicalExam.fromJson(Map<String, dynamic> json) => MedicalExam(
        id: (json['id'] as num?)?.toInt() ?? 0,
        kind: '${json['kind'] ?? ''}',
        dueOn: _day(json['due_on']),
        lastDoneOn: _day(json['last_done_on']),
        state: '${json['state'] ?? 'ok'}',
        employee: _person(json['employee']),
      );
}

/// Время приёма в медпункте — время предприятия, без пояса.
class MedicalSlot {
  const MedicalSlot(
      {required this.id,
      required this.kind,
      this.startsAt,
      this.booked = false,
      this.mine = false,
      this.employee});

  final int id;
  final String kind;
  final DateTime? startsAt;
  final bool booked;
  final bool mine;
  final AssignPerson? employee;

  factory MedicalSlot.fromJson(Map<String, dynamic> json) => MedicalSlot(
        id: (json['id'] as num?)?.toInt() ?? 0,
        kind: '${json['kind'] ?? 'exam'}',
        startsAt: _day(json['starts_at']),
        booked: json['booked'] == true,
        mine: json['mine'] == true,
        employee: _person(json['employee']),
      );
}

class MedicalMine {
  const MedicalMine(
      {this.medic = false,
      this.exams = const [],
      this.bookings = const [],
      this.free = const []});

  final bool medic;
  final List<MedicalExam> exams;
  final List<MedicalSlot> bookings;
  final List<MedicalSlot> free;

  factory MedicalMine.fromJson(Map<String, dynamic> json) => MedicalMine(
        medic: json['medic'] == true,
        exams: _list(json['exams'], MedicalExam.fromJson),
        bookings: _list(json['bookings'], MedicalSlot.fromJson),
        free: _list(json['free'], MedicalSlot.fromJson),
      );
}

class MedicalDesk {
  const MedicalDesk({this.slots = const [], this.due = const []});

  final List<MedicalSlot> slots;
  final List<MedicalExam> due;

  factory MedicalDesk.fromJson(Map<String, dynamic> json) => MedicalDesk(
        slots: _list(json['slots'], MedicalSlot.fromJson),
        due: _list(json['due'], MedicalExam.fromJson),
      );
}

class MedicalResult {
  const MedicalResult({this.ok = false, this.count, this.error, this.problem});

  final bool ok;

  /// Сколько открыто приёмов, назначено сроков или отправлено напоминаний.
  final int? count;
  final String? error;
  final LoadProblem? problem;
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

Future<Map<String, dynamic>> _get(String path) async {
  try {
    final response = await http
        .get(_uri(path), headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

Future<MedicalMine> fetchMyMedical() async =>
    MedicalMine.fromJson(await _get('/api/medical'));

Future<MedicalDesk> fetchMedicalDesk(DateTime day) async =>
    MedicalDesk.fromJson(await _get('/api/medical/desk?date=${isoDay(day)}'));

Future<List<AssignPerson>> searchMedicalPeople(String query) async {
  final body =
      await _get('/api/medical/people?q=${Uri.encodeQueryComponent(query)}');
  return _list(body['people'], AssignPerson.fromJson);
}

Future<List<String>> fetchMedicalDepartments() async {
  final body = await _get('/api/medical/departments');
  return _list(body['departments'], (d) => '${d['name'] ?? ''}');
}

Future<MedicalResult> _send(
    Future<http.Response> Function(Map<String, String>) call) async {
  try {
    final response =
        await call(await authHeaders()).timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const MedicalResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if (response.statusCode == 200 || response.statusCode == 201) {
      final count = parsed['added'] ?? parsed['count'] ?? parsed['reminded'];
      return MedicalResult(ok: true, count: (count as num?)?.toInt());
    }
    final error = parsed['error'];
    return MedicalResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return MedicalResult(problem: problemOf(e));
  }
}

Future<MedicalResult> _post(String path, Map<String, Object?> body) =>
    _send((headers) =>
        http.post(_uri(path), headers: headers, body: jsonEncode(body)));

Future<MedicalResult> bookMedicalSlot(int id) =>
    _post('/api/medical/slots/$id/book', const {});

Future<MedicalResult> cancelMedicalSlot(int id) =>
    _post('/api/medical/slots/$id/cancel', const {});

Future<MedicalResult> deleteMedicalSlot(int id) => _send(
    (headers) => http.delete(_uri('/api/medical/slots/$id'), headers: headers));

Future<MedicalResult> openMedicalSlots(DateTime day,
        {required String kind,
        required String from,
        required String to,
        required String step}) =>
    _post('/api/medical/slots', {
      'date': isoDay(day),
      'kind': kind,
      'from': from,
      'to': to,
      'step': step,
    });

/// Назначить срок одному человеку ([employeeId]) или подразделению.
Future<MedicalResult> setMedicalExam(
        {required String kind,
        required DateTime dueOn,
        String? employeeId,
        String? department}) =>
    _post('/api/medical/exams', {
      'kind': kind,
      'due_on': isoDay(dueOn),
      if (employeeId != null) 'employee_ids': [employeeId],
      if (department != null) 'department': department,
    });

Future<MedicalResult> markMedicalExamDone(int id) =>
    _post('/api/medical/exams/$id', {'action': 'done'});

Future<MedicalResult> remindMedicalDue() =>
    _post('/api/medical/remind-due', const {});
