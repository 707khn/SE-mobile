import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'assignment_request.dart' show AssignPerson;
import 'lunch_order_request.dart' show lunchDay;

const maintenanceKinds = ['service', 'current', 'overhaul', 'inspection'];

DateTime? _day(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

AssignPerson? _person(Object? raw) =>
    raw is Map ? AssignPerson.fromJson(Map<String, dynamic>.from(raw)) : null;

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) =>
    ((raw as List?) ?? const [])
        .whereType<Map>()
        .map((e) => parse(Map<String, dynamic>.from(e)))
        .toList();

class Equipment {
  const Equipment({
    required this.id,
    required this.name,
    this.inventoryNo = '',
    this.location = '',
    this.master,
    this.engineer,
    this.plans = const [],
  });

  final int id;
  final String name;
  final String inventoryNo;
  final String location;
  final AssignPerson? master;
  final AssignPerson? engineer;
  final List<MaintenancePlan> plans;

  factory Equipment.fromJson(Map<String, dynamic> json) => Equipment(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: '${json['name'] ?? ''}',
        inventoryNo: '${json['inventory_no'] ?? ''}',
        location: '${json['location'] ?? ''}',
        master: _person(json['master']),
        engineer: _person(json['engineer']),
        plans: _list(json['plans'], MaintenancePlan.fromJson),
      );
}

class MaintenanceRecord {
  const MaintenanceRecord(
      {required this.action,
      this.plannedOn,
      this.doneOn,
      this.newOn,
      this.note = '',
      this.at,
      this.actor});

  final String action;
  final DateTime? plannedOn;
  final DateTime? doneOn;
  final DateTime? newOn;
  final String note;
  final DateTime? at;
  final AssignPerson? actor;

  factory MaintenanceRecord.fromJson(Map<String, dynamic> json) =>
      MaintenanceRecord(
        action: '${json['action'] ?? ''}',
        plannedOn: _day(json['planned_on']),
        doneOn: _day(json['done_on']),
        newOn: _day(json['new_on']),
        note: '${json['note'] ?? ''}',
        at: _time(json['at']),
        actor: _person(json['actor']),
      );
}

/// Вид работ по оборудованию: [state] — overdue, week или later.
class MaintenancePlan {
  const MaintenancePlan({
    required this.id,
    required this.kind,
    this.equipmentId = 0,
    this.everyMonths = 1,
    this.nextOn,
    this.hours,
    this.note = '',
    this.state = 'later',
    this.equipment,
    this.canMark = false,
    this.history = const [],
  });

  final int id;
  final String kind;
  final int equipmentId;
  final int everyMonths;
  final DateTime? nextOn;
  final int? hours;
  final String note;
  final String state;
  final Equipment? equipment;
  final bool canMark;
  final List<MaintenanceRecord> history;

  factory MaintenancePlan.fromJson(Map<String, dynamic> json) =>
      MaintenancePlan(
        id: (json['id'] as num?)?.toInt() ?? 0,
        kind: '${json['kind'] ?? 'service'}',
        equipmentId: (json['equipment_id'] as num?)?.toInt() ?? 0,
        everyMonths: (json['every_months'] as num?)?.toInt() ?? 1,
        nextOn: _day(json['next_on']),
        hours: (json['hours'] as num?)?.toInt(),
        note: '${json['note'] ?? ''}',
        state: '${json['state'] ?? 'later'}',
        equipment: json['equipment'] is Map
            ? Equipment.fromJson(Map<String, dynamic>.from(json['equipment']))
            : null,
        canMark: json['can_mark'] == true,
        history: _list(json['history'], MaintenanceRecord.fromJson),
      );
}

class MaintenanceSchedule {
  const MaintenanceSchedule({this.planner = false, this.items = const []});

  final bool planner;
  final List<MaintenancePlan> items;

  factory MaintenanceSchedule.fromJson(Map<String, dynamic> json) =>
      MaintenanceSchedule(
        planner: json['planner'] == true,
        items: _list(json['items'], MaintenancePlan.fromJson),
      );
}

class EquipmentList {
  const EquipmentList({this.planner = false, this.items = const []});

  final bool planner;
  final List<Equipment> items;

  factory EquipmentList.fromJson(Map<String, dynamic> json) => EquipmentList(
        planner: json['planner'] == true,
        items: _list(json['items'], Equipment.fromJson),
      );
}

class MaintenanceResult {
  const MaintenanceResult({this.ok = false, this.id, this.error, this.problem});

  final bool ok;

  /// Номер заведённого оборудования.
  final int? id;
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

Future<MaintenanceSchedule> fetchMaintenanceSchedule() async =>
    MaintenanceSchedule.fromJson(await _get('/api/maintenance'));

Future<EquipmentList> fetchEquipmentList() async =>
    EquipmentList.fromJson(await _get('/api/maintenance/equipment'));

Future<(Equipment, bool)> fetchEquipment(int id) async {
  final body = await _get('/api/maintenance/equipment/$id');
  return (
    Equipment.fromJson(body['item'] as Map<String, dynamic>),
    body['planner'] == true
  );
}

Future<List<AssignPerson>> searchMaintenancePeople(String query) async {
  final body = await _get(
      '/api/maintenance/people?q=${Uri.encodeQueryComponent(query)}');
  return _list(body['people'], AssignPerson.fromJson);
}

Future<MaintenanceResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const MaintenanceResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if (response.statusCode == 200 || response.statusCode == 201) {
      final item = parsed['item'];
      return MaintenanceResult(
          ok: true, id: item is Map ? (item['id'] as num?)?.toInt() : null);
    }
    final error = parsed['error'];
    return MaintenanceResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return MaintenanceResult(problem: problemOf(e));
  }
}

Future<MaintenanceResult> createEquipment(
        {required String name,
        String inventoryNo = '',
        String location = '',
        String? masterId,
        String? engineerId}) =>
    _post('/api/maintenance/equipment', {
      'name': name,
      'inventory_no': inventoryNo,
      'location': location,
      if (masterId != null) 'master_id': masterId,
      if (engineerId != null) 'engineer_id': engineerId,
    });

Future<MaintenanceResult> retireEquipment(int id) =>
    _post('/api/maintenance/equipment/$id', {'active': false});

Future<MaintenanceResult> createMaintenancePlan(
        {required int equipmentId,
        required String kind,
        required String everyMonths,
        required DateTime nextOn,
        String hours = ''}) =>
    _post('/api/maintenance/plans', {
      'equipment_id': equipmentId,
      'kind': kind,
      'every_months': everyMonths,
      'next_on': lunchDay(nextOn),
      if (hours.isNotEmpty) 'hours': hours,
    });

Future<MaintenanceResult> markMaintenanceDone(int planId, {String note = ''}) =>
    _post('/api/maintenance/plans/$planId',
        {'action': 'done', if (note.isNotEmpty) 'note': note});

Future<MaintenanceResult> postponeMaintenance(
        int planId, DateTime nextOn, String note) =>
    _post('/api/maintenance/plans/$planId',
        {'action': 'postpone', 'next_on': lunchDay(nextOn), 'note': note});

Future<MaintenanceResult> removeMaintenancePlan(int planId) =>
    _post('/api/maintenance/plans/$planId', {'action': 'remove'});
