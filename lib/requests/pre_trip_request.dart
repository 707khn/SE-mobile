import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItPerson;
import 'purchase_request.dart' show isoDay;

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

DateTime? _day(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

int? _int(Object? raw) => (raw as num?)?.toInt();
double? _double(Object? raw) => (raw as num?)?.toDouble();

/// Медосмотр. Показатели приходят только медпункту и самому водителю.
class PreTripExam {
  const PreTripExam({
    required this.id,
    required this.admitted,
    this.kind = 'pre',
    this.date,
    this.at,
    this.systolic,
    this.diastolic,
    this.pulse,
    this.temperature,
    this.alcohol,
    this.complaints = '',
    this.reason = '',
    this.warnings = const [],
  });

  final int id;
  final String kind;
  final DateTime? date;
  final DateTime? at;
  final bool admitted;
  final int? systolic;
  final int? diastolic;
  final int? pulse;
  final double? temperature;
  final double? alcohol;
  final String complaints;
  final String reason;

  /// pressure, pulse, temperature, alcohol — что вышло за границы.
  final List<String> warnings;

  bool get hasVitals => systolic != null;

  factory PreTripExam.fromJson(Map<String, dynamic> json) => PreTripExam(
        id: _int(json['id']) ?? 0,
        kind: '${json['kind'] ?? 'pre'}',
        date: _day(json['date']),
        at: _time(json['at']),
        admitted: json['admitted'] == true,
        systolic: _int(json['systolic']),
        diastolic: _int(json['diastolic']),
        pulse: _int(json['pulse']),
        temperature: _double(json['temperature']),
        alcohol: _double(json['alcohol']),
        complaints: '${json['complaints'] ?? ''}',
        reason: '${json['reason'] ?? ''}',
        warnings: ((json['warnings'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
      );

  static PreTripExam? maybe(Object? raw) =>
      raw is Map ? PreTripExam.fromJson(Map<String, dynamic>.from(raw)) : null;
}

class VehicleCheck {
  const VehicleCheck(
      {required this.plate,
      required this.ok,
      this.odometer,
      this.reason = '',
      this.at});

  final String plate;
  final bool ok;
  final int? odometer;
  final String reason;
  final DateTime? at;

  static VehicleCheck? maybe(Object? raw) => raw is Map
      ? VehicleCheck(
          plate: '${raw['plate'] ?? ''}',
          ok: raw['ok'] == true,
          odometer: _int(raw['odometer']),
          reason: '${raw['reason'] ?? ''}',
          at: _time(raw['at']),
        )
      : null;
}

/// Строка журнала: водитель и его допуск на день.
class PreTripRow {
  const PreTripRow(
      {required this.driver,
      required this.status,
      this.exam,
      this.postExam,
      this.check});

  final ItPerson driver;

  /// pending, med_ok, admitted, not_admitted.
  final String status;
  final PreTripExam? exam;
  final PreTripExam? postExam;
  final VehicleCheck? check;
}

/// Что вышло за границы — те же правила, что на сервере, чтобы медработник
/// видел подсветку, пока вводит.
class PreTripLimits {
  const PreTripLimits(
      {this.systolic = 140,
      this.diastolic = 90,
      this.pulseLow = 50,
      this.pulseHigh = 100,
      this.temperature = 37.0});

  final int systolic;
  final int diastolic;
  final int pulseLow;
  final int pulseHigh;
  final double temperature;

  factory PreTripLimits.fromJson(Object? raw) {
    if (raw is! Map) return const PreTripLimits();
    return PreTripLimits(
      systolic: _int(raw['systolic']) ?? 140,
      diastolic: _int(raw['diastolic']) ?? 90,
      pulseLow: _int(raw['pulse_low']) ?? 50,
      pulseHigh: _int(raw['pulse_high']) ?? 100,
      temperature: _double(raw['temperature']) ?? 37.0,
    );
  }

  List<String> warnings(
      {int? systolic,
      int? diastolic,
      int? pulse,
      double? temperature,
      double? alcohol}) {
    return [
      if ((systolic != null && systolic >= this.systolic) ||
          (diastolic != null && diastolic >= this.diastolic))
        'pressure',
      if (pulse != null && (pulse < pulseLow || pulse > pulseHigh)) 'pulse',
      if (temperature != null && temperature >= this.temperature) 'temperature',
      if (alcohol != null && alcohol > 0) 'alcohol',
    ];
  }
}

class PreTripMe {
  const PreTripMe(
      {required this.status, this.exam, this.check, this.history = const []});

  final String status;
  final PreTripExam? exam;
  final VehicleCheck? check;
  final List<PreTripExam> history;
}

class PreTripDay {
  const PreTripDay({
    required this.date,
    this.medic = false,
    this.mechanic = false,
    this.manager = false,
    this.driver = false,
    this.rows,
    this.counts = const {},
    this.me,
    this.limits = const PreTripLimits(),
  });

  final DateTime date;
  final bool medic;
  final bool mechanic;
  final bool manager;
  final bool driver;

  /// Журнал — только медпункту, механику, руководству.
  final List<PreTripRow>? rows;
  final Map<String, int> counts;
  final PreTripMe? me;
  final PreTripLimits limits;

  factory PreTripDay.fromJson(Map<String, dynamic> json) {
    final roles = json['roles'] is Map ? json['roles'] as Map : const {};
    final me = json['me'];
    final rows = json['drivers'];
    final counts = json['counts'];
    return PreTripDay(
      date: _day(json['date']) ?? DateTime.now(),
      medic: roles['medic'] == true,
      mechanic: roles['mechanic'] == true,
      manager: roles['manager'] == true,
      driver: roles['driver'] == true,
      rows: rows is List
          ? rows.whereType<Map>().map((r) {
              return PreTripRow(
                driver: ItPerson.fromJson(r['driver']) ??
                    const ItPerson(id: '', name: ''),
                status: '${r['status'] ?? 'pending'}',
                exam: PreTripExam.maybe(r['exam']),
                postExam: PreTripExam.maybe(r['post_exam']),
                check: VehicleCheck.maybe(r['check']),
              );
            }).toList()
          : null,
      counts: counts is Map
          ? {
              for (final e in counts.entries)
                '${e.key}': (e.value as num?)?.toInt() ?? 0
            }
          : const {},
      me: me is Map
          ? PreTripMe(
              status: '${me['status'] ?? 'pending'}',
              exam: PreTripExam.maybe(me['exam']),
              check: VehicleCheck.maybe(me['check']),
              history: ((me['history'] as List?) ?? const [])
                  .whereType<Map>()
                  .map(
                      (e) => PreTripExam.fromJson(Map<String, dynamic>.from(e)))
                  .toList(),
            )
          : null,
      limits: PreTripLimits.fromJson(json['limits']),
    );
  }
}

class PreTripResult {
  const PreTripResult({this.ok = false, this.error, this.problem});

  final bool ok;
  final String? error;
  final LoadProblem? problem;
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

Future<PreTripDay> fetchPreTripDay({DateTime? day}) async {
  final path = '/api/pretrip${day == null ? '' : '?date=${isoDay(day)}'}';
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
    return PreTripDay.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

Future<PreTripResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const PreTripResult(problem: LoadProblem.denied);
    }
    if (response.statusCode == 201 || response.statusCode == 200) {
      return const PreTripResult(ok: true);
    }
    Object? error;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) error = decoded['error'];
    } catch (_) {}
    return PreTripResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return PreTripResult(problem: problemOf(e));
  }
}

Future<PreTripResult> recordPreTripExam({
  required String driverId,
  required String kind,
  required int systolic,
  required int diastolic,
  int? pulse,
  double? temperature,
  required double alcohol,
  String complaints = '',
  required bool admitted,
  String reason = '',
}) =>
    _post('/api/pretrip/exams', {
      'employee_id': driverId,
      'kind': kind,
      'systolic': systolic,
      'diastolic': diastolic,
      if (pulse != null) 'pulse': pulse,
      if (temperature != null) 'temperature': temperature,
      'alcohol': alcohol,
      if (complaints.isNotEmpty) 'complaints': complaints,
      'admitted': admitted,
      if (reason.isNotEmpty) 'reason': reason,
    });

Future<PreTripResult> recordVehicleCheck({
  required String driverId,
  required String plate,
  int? odometer,
  required bool ok,
  String reason = '',
}) =>
    _post('/api/pretrip/checks', {
      'employee_id': driverId,
      'plate': plate,
      if (odometer != null) 'odometer': odometer,
      'ok': ok,
      if (reason.isNotEmpty) 'reason': reason,
    });
