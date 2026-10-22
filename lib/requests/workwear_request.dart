import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'assignment_request.dart' show AssignPerson;

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

DateTime? _day(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

AssignPerson? _person(Object? raw) =>
    raw is Map ? AssignPerson.fromJson(Map<String, dynamic>.from(raw)) : null;

/// Что выдано человеку. [due]: ok, soon, overdue или none — без срока.
class WorkwearIssue {
  const WorkwearIssue({
    required this.id,
    required this.item,
    this.size = '',
    this.quantity = 1,
    this.issuedOn,
    this.wearMonths,
    this.dueOn,
    this.due = 'none',
    this.note = '',
    this.employee,
  });

  final int id;
  final String item;
  final String size;
  final int quantity;
  final DateTime? issuedOn;
  final int? wearMonths;
  final DateTime? dueOn;
  final String due;
  final String note;
  final AssignPerson? employee;

  factory WorkwearIssue.fromJson(Map<String, dynamic> json) => WorkwearIssue(
        id: (json['id'] as num?)?.toInt() ?? 0,
        item: '${json['item'] ?? ''}',
        size: '${json['size'] ?? ''}',
        quantity: (json['quantity'] as num?)?.toInt() ?? 1,
        issuedOn: _day(json['issued_on']),
        wearMonths: (json['wear_months'] as num?)?.toInt(),
        dueOn: _day(json['due_on']),
        due: '${json['due'] ?? 'none'}',
        note: '${json['note'] ?? ''}',
        employee: _person(json['employee']),
      );
}

/// Сдано в стирку (wash) или ремонт (repair): accepted, ready, collected.
class WorkwearLaundry {
  const WorkwearLaundry({
    required this.id,
    required this.kind,
    required this.items,
    this.note = '',
    this.status = 'accepted',
    this.acceptedAt,
    this.readyAt,
    this.employee,
  });

  final int id;
  final String kind;
  final String items;
  final String note;
  final String status;
  final DateTime? acceptedAt;
  final DateTime? readyAt;
  final AssignPerson? employee;

  factory WorkwearLaundry.fromJson(Map<String, dynamic> json) =>
      WorkwearLaundry(
        id: (json['id'] as num?)?.toInt() ?? 0,
        kind: '${json['kind'] ?? 'wash'}',
        items: '${json['items'] ?? ''}',
        note: '${json['note'] ?? ''}',
        status: '${json['status'] ?? 'accepted'}',
        acceptedAt: _time(json['accepted_at']),
        readyAt: _time(json['ready_at']),
        employee: _person(json['employee']),
      );
}

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) =>
    ((raw as List?) ?? const [])
        .whereType<Map>()
        .map((e) => parse(Map<String, dynamic>.from(e)))
        .toList();

class WorkwearCard {
  const WorkwearCard(
      {this.staff = false,
      this.employee,
      this.issues = const [],
      this.laundry = const []});

  final bool staff;
  final AssignPerson? employee;
  final List<WorkwearIssue> issues;
  final List<WorkwearLaundry> laundry;

  factory WorkwearCard.fromJson(Map<String, dynamic> json) => WorkwearCard(
        staff: json['staff'] == true,
        employee: _person(json['employee']),
        issues: _list(json['issues'], WorkwearIssue.fromJson),
        laundry: _list(json['laundry'], WorkwearLaundry.fromJson),
      );
}

class WorkwearDesk {
  const WorkwearDesk({this.laundry = const [], this.due = const []});

  final List<WorkwearLaundry> laundry;
  final List<WorkwearIssue> due;

  factory WorkwearDesk.fromJson(Map<String, dynamic> json) => WorkwearDesk(
        laundry: _list(json['laundry'], WorkwearLaundry.fromJson),
        due: _list(json['due'], WorkwearIssue.fromJson),
      );
}

class WorkwearResult {
  const WorkwearResult(
      {this.ok = false, this.reminded, this.error, this.problem});

  final bool ok;
  final int? reminded;
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

Future<WorkwearCard> fetchMyWorkwear() async =>
    WorkwearCard.fromJson(await _get('/api/workwear'));

Future<WorkwearDesk> fetchWorkwearDesk() async =>
    WorkwearDesk.fromJson(await _get('/api/workwear/staff'));

Future<WorkwearCard> fetchWorkwearCard(String employeeId) async =>
    WorkwearCard.fromJson(await _get(
        '/api/workwear/employees/${Uri.encodeComponent(employeeId)}'));

Future<List<AssignPerson>> searchWorkwearPeople(String query) async {
  final body =
      await _get('/api/workwear/people?q=${Uri.encodeQueryComponent(query)}');
  return _list(body['people'], AssignPerson.fromJson);
}

Future<WorkwearResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const WorkwearResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if (response.statusCode == 200 || response.statusCode == 201) {
      return WorkwearResult(
          ok: true, reminded: (parsed['reminded'] as num?)?.toInt());
    }
    final error = parsed['error'];
    return WorkwearResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return WorkwearResult(problem: problemOf(e));
  }
}

/// Записать выдачу: поля как в диалоге — item, size, quantity, wear_months.
Future<WorkwearResult> issueWorkwear(
        String employeeId, Map<String, String> fields) =>
    _post('/api/workwear/issues', {'employee_id': employeeId, ...fields});

/// replace — выдали такое же новое, return — сдал или списано.
Future<WorkwearResult> workwearIssueAction(int id, String action) =>
    _post('/api/workwear/issues/$id', {'action': action});

Future<WorkwearResult> remindWorkwearDue() =>
    _post('/api/workwear/remind-due', const {});

Future<WorkwearResult> acceptLaundry(
        String employeeId, String kind, String items) =>
    _post('/api/workwear/laundry',
        {'employee_id': employeeId, 'kind': kind, 'items': items});

/// ready — готово, человеку «заберите»; collected — забрал.
Future<WorkwearResult> laundryAction(int id, String action) =>
    _post('/api/workwear/laundry/$id', {'action': action});
