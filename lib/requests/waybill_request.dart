import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItPerson;
import 'stock_balance_request.dart' show stockQuantity;

double? _double(Object? raw) => (raw as num?)?.toDouble();
int? _int(Object? raw) => (raw as num?)?.toInt();

/// 35.5 → «35,5».
String litres(double? value) => value == null ? '—' : stockQuantity(value);

class WaybillTrip {
  const WaybillTrip({
    required this.id,
    required this.origin,
    required this.destination,
    this.purpose = '',
    this.customer = '',
    this.departed = '',
    this.arrived = '',
  });

  final int id;
  final String origin;
  final String destination;
  final String purpose;
  final String customer;
  final String departed;
  final String arrived;

  /// «09:10–09:40».
  String get when => [departed, arrived].where((s) => s.isNotEmpty).join('–');

  static WaybillTrip? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return WaybillTrip(
      id: _int(raw['id']) ?? 0,
      origin: '${raw['origin'] ?? ''}',
      destination: '${raw['destination'] ?? ''}',
      purpose: '${raw['purpose'] ?? ''}',
      customer: '${raw['customer'] ?? ''}',
      departed: '${raw['departed'] ?? ''}',
      arrived: '${raw['arrived'] ?? ''}',
    );
  }
}

class Waybill {
  const Waybill({
    required this.id,
    required this.plate,
    this.date,
    this.status = 'open',
    this.odometerOut = 0,
    this.odometerIn,
    this.fuelOut = 0,
    this.fuelAdded,
    this.fuelIn,
    this.distance,
    this.fuelUsed,
    this.note = '',
    this.driver,
    this.reviewer,
    this.trips = const [],
    this.canEdit = false,
    this.canReview = false,
  });

  final int id;
  final String plate;
  final DateTime? date;

  /// open, returned, closed.
  final String status;
  final int odometerOut;
  final int? odometerIn;
  final double fuelOut;
  final double? fuelAdded;
  final double? fuelIn;
  final int? distance;
  final double? fuelUsed;

  /// Почему механик вернул лист водителю.
  final String note;
  final ItPerson? driver;
  final ItPerson? reviewer;
  final List<WaybillTrip> trips;
  final bool canEdit;
  final bool canReview;

  factory Waybill.fromJson(Map<String, dynamic> json) {
    final date = json['date'];
    return Waybill(
      id: _int(json['id']) ?? 0,
      plate: '${json['plate'] ?? ''}',
      date: date is String ? DateTime.tryParse(date) : null,
      status: '${json['status'] ?? 'open'}',
      odometerOut: _int(json['odometer_out']) ?? 0,
      odometerIn: _int(json['odometer_in']),
      fuelOut: _double(json['fuel_out']) ?? 0,
      fuelAdded: _double(json['fuel_added']),
      fuelIn: _double(json['fuel_in']),
      distance: _int(json['distance']),
      fuelUsed: _double(json['fuel_used']),
      note: '${json['note'] ?? ''}',
      driver: ItPerson.fromJson(json['driver']),
      reviewer: ItPerson.fromJson(json['reviewer']),
      trips: ((json['trips'] as List?) ?? const [])
          .map(WaybillTrip.fromJson)
          .whereType<WaybillTrip>()
          .toList(),
      canEdit: json['can_edit'] == true,
      canReview: json['can_review'] == true,
    );
  }
}

/// Можно ли сегодня открыть лист.
class WaybillReady {
  const WaybillReady({
    this.examined = false,
    this.admitted = false,
    this.checked = false,
    this.released = false,
    this.plate = '',
    this.odometer,
    this.fuel,
    this.openId,
  });

  final bool examined;
  final bool admitted;
  final bool checked;
  final bool released;
  final String plate;
  final int? odometer;

  /// Сколько было в баке на возврате прошлый раз.
  final double? fuel;
  final int? openId;

  bool get canOpen => admitted && released && openId == null;

  static WaybillReady fromJson(Object? raw) {
    if (raw is! Map) return const WaybillReady();
    return WaybillReady(
      examined: raw['examined'] == true,
      admitted: raw['admitted'] == true,
      checked: raw['checked'] == true,
      released: raw['released'] == true,
      plate: '${raw['plate'] ?? ''}',
      odometer: _int(raw['odometer']),
      fuel: _double(raw['fuel']),
      openId: _int(raw['open_id']),
    );
  }
}

class WaybillTotals {
  const WaybillTotals(
      {this.count = 0,
      this.open = 0,
      this.returned = 0,
      this.distance = 0,
      this.fuelUsed = 0});

  final int count;
  final int open;
  final int returned;
  final int distance;
  final double fuelUsed;
}

class WaybillOverview {
  const WaybillOverview({
    this.staff = false,
    this.driver = false,
    this.ready = const WaybillReady(),
    this.mine = const [],
    this.date,
    this.items = const [],
    this.totals = const WaybillTotals(),
  });

  final bool staff;
  final bool driver;
  final WaybillReady ready;
  final List<Waybill> mine;
  final DateTime? date;
  final List<Waybill> items;
  final WaybillTotals totals;

  factory WaybillOverview.fromJson(Map<String, dynamic> json) {
    List<Waybill> list(Object? raw) => ((raw as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Waybill.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final totals = json['totals'];
    final date = json['date'];
    return WaybillOverview(
      staff: json['staff'] == true,
      driver: json['driver'] == true,
      ready: WaybillReady.fromJson(json['ready']),
      mine: list(json['mine']),
      date: date is String ? DateTime.tryParse(date) : null,
      items: list(json['items']),
      totals: totals is Map
          ? WaybillTotals(
              count: _int(totals['count']) ?? 0,
              open: _int(totals['open']) ?? 0,
              returned: _int(totals['returned']) ?? 0,
              distance: _int(totals['distance']) ?? 0,
              fuelUsed: _double(totals['fuel_used']) ?? 0,
            )
          : const WaybillTotals(),
    );
  }
}

class WaybillResult {
  const WaybillResult({this.item, this.error, this.problem});

  final Waybill? item;
  final String? error;
  final LoadProblem? problem;

  bool get ok => item != null;
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

String _isoDay(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

Future<WaybillOverview> fetchWaybills({DateTime? day}) async =>
    WaybillOverview.fromJson(await _get(
        '/api/waybills${day == null ? '' : '?date=${_isoDay(day)}'}'));

Future<Waybill> fetchWaybill(int id) async {
  final body = await _get('/api/waybills/$id');
  return Waybill.fromJson(body['item'] as Map<String, dynamic>);
}

Future<WaybillResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const WaybillResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return WaybillResult(
          item: Waybill.fromJson(Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return WaybillResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return WaybillResult(problem: problemOf(e));
  }
}

Future<WaybillResult> openWaybill(
        {required String fuelOut, String odometerOut = ''}) =>
    _post('/api/waybills', {
      'fuel_out': fuelOut,
      if (odometerOut.isNotEmpty) 'odometer_out': odometerOut,
    });

/// trip, trip_remove, return, close, reopen.
Future<WaybillResult> waybillAction(int id, String action,
        [Map<String, Object?> fields = const {}]) =>
    _post('/api/waybills/$id', {'action': action, ...fields});
