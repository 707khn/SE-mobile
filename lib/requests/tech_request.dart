import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'assignment_request.dart' show AssignPerson;

/// Время завода «2030-03-09T09:00» — без пояса, как его объявили.
DateTime? _plant(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

AssignPerson? _person(Object? raw) =>
    raw is Map ? AssignPerson.fromJson(Map<String, dynamic>.from(raw)) : null;

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) =>
    ((raw as List?) ?? const [])
        .whereType<Map>()
        .map((e) => parse(Map<String, dynamic>.from(e)))
        .toList();

/// Плановое отключение. [state]: planned, now, past или cancelled.
class Outage {
  const Outage({
    required this.id,
    required this.kind,
    required this.startsAt,
    required this.endsAt,
    this.note = '',
    this.departments = const [],
    this.mine = true,
    this.state = 'planned',
    this.author,
  });

  final int id;
  final String kind;
  final DateTime startsAt;
  final DateTime endsAt;
  final String note;

  /// Пусто — всё предприятие.
  final List<String> departments;

  /// Касается подразделения того, кто смотрит.
  final bool mine;
  final String state;
  final AssignPerson? author;

  static Outage? fromJson(Map<String, dynamic> json) {
    final start = _plant(json['starts_at']);
    final end = _plant(json['ends_at']);
    if (start == null || end == null) return null;
    return Outage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      kind: '${json['kind'] ?? 'other'}',
      startsAt: start,
      endsAt: end,
      note: '${json['note'] ?? ''}',
      departments: ((json['departments'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
      mine: json['mine'] != false,
      state: '${json['state'] ?? 'planned'}',
      author: _person(json['author']),
    );
  }
}

class OutageList {
  const OutageList({this.staff = false, this.items = const []});

  final bool staff;
  final List<Outage> items;
}

/// Техника, что числится за сотрудником.
class ItAsset {
  const ItAsset({
    required this.id,
    required this.kind,
    required this.model,
    this.inventoryNo = '',
    this.serial = '',
    this.room = '',
    this.note = '',
    this.holder,
  });

  final int id;
  final String kind;
  final String model;
  final String inventoryNo;
  final String serial;
  final String room;
  final String note;
  final AssignPerson? holder;

  factory ItAsset.fromJson(Map<String, dynamic> json) => ItAsset(
        id: (json['id'] as num?)?.toInt() ?? 0,
        kind: '${json['kind'] ?? 'other'}',
        model: '${json['model'] ?? ''}',
        inventoryNo: '${json['inventory_no'] ?? ''}',
        serial: '${json['serial'] ?? ''}',
        room: '${json['room'] ?? ''}',
        note: '${json['note'] ?? ''}',
        holder: _person(json['holder']),
      );
}

class MyAssets {
  const MyAssets({this.staff = false, this.items = const []});

  final bool staff;
  final List<ItAsset> items;
}

class TechResult {
  const TechResult({this.ok = false, this.notified, this.error, this.problem});

  final bool ok;
  final int? notified;
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

Future<TechResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const TechResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if (response.statusCode == 200 || response.statusCode == 201) {
      return TechResult(
          ok: true, notified: (parsed['notified'] as num?)?.toInt());
    }
    final error = parsed['error'];
    return TechResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return TechResult(problem: problemOf(e));
  }
}

Future<OutageList> fetchOutages() async {
  final body = await _get('/api/outages');
  return OutageList(
    staff: body['staff'] == true,
    items: ((body['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Outage.fromJson(Map<String, dynamic>.from(e)))
        .whereType<Outage>()
        .toList(),
  );
}

Future<List<String>> fetchOutageDepartments() async {
  final body = await _get('/api/outages/departments');
  return ((body['departments'] as List?) ?? const [])
      .whereType<String>()
      .toList();
}

String _stamp(DateTime at) =>
    '${at.year.toString().padLeft(4, '0')}-${at.month.toString().padLeft(2, '0')}-'
    '${at.day.toString().padLeft(2, '0')} ${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}';

Future<TechResult> announceOutage({
  required String kind,
  required DateTime startsAt,
  required DateTime endsAt,
  String note = '',
  List<String> departments = const [],
}) =>
    _post('/api/outages', {
      'kind': kind,
      'starts_at': _stamp(startsAt),
      'ends_at': _stamp(endsAt),
      'note': note,
      'departments': departments,
    });

Future<TechResult> cancelOutage(int id) =>
    _post('/api/outages/$id', {'action': 'cancel'});

Future<MyAssets> fetchMyAssets() async {
  final body = await _get('/api/it-assets/mine');
  return MyAssets(
      staff: body['staff'] == true,
      items: _list(body['items'], ItAsset.fromJson));
}

Future<List<ItAsset>> searchAssets(String query) async {
  final body =
      await _get('/api/it-assets?q=${Uri.encodeQueryComponent(query)}');
  return _list(body['items'], ItAsset.fromJson);
}

Future<List<AssignPerson>> searchAssetPeople(String query) async {
  final body =
      await _get('/api/it-assets/people?q=${Uri.encodeQueryComponent(query)}');
  return _list(body['people'], AssignPerson.fromJson);
}

/// Поля как в диалоге: model, inventory_no, serial, room.
Future<TechResult> addAsset(String kind, Map<String, String> fields) =>
    _post('/api/it-assets', {'kind': kind, ...fields});

/// assign (с [employeeId]), release, writeoff.
Future<TechResult> assetAction(int id, String action, {String? employeeId}) =>
    _post('/api/it-assets/$id', {
      'action': action,
      if (employeeId != null) 'employee_id': employeeId,
    });
