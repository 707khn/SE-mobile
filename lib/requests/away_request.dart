import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

const awayReasons = <String>['vacation', 'sick', 'trip', 'other'];

/// Отметка «меня нет на месте»: до какого числа и кто замещает.
class AwayNote {
  const AwayNote({
    required this.reason,
    required this.start,
    required this.end,
    this.active = false,
    this.deputy = '',
    this.deputyExtension = '',
    this.deputyMobile = '',
    this.note = '',
  });

  final String reason;
  final DateTime start;
  final DateTime end;

  /// Действует сегодня (а не поставлена заранее).
  final bool active;
  final String deputy;
  final String deputyExtension;
  final String deputyMobile;
  final String note;

  /// Справочник живёт в кеше: отметка, у которой срок вышел, уже ничего не
  /// значит, даже если с сервера её ещё не убрали.
  bool shownOn(DateTime today) {
    final day = DateTime(today.year, today.month, today.day);
    return !day.isBefore(start) && !day.isAfter(end);
  }

  static AwayNote? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = DateTime.tryParse('${raw['start'] ?? ''}');
    final end = DateTime.tryParse('${raw['end'] ?? ''}');
    if (start == null || end == null) return null;
    return AwayNote(
      reason: awayReasons.contains(raw['reason']) ? raw['reason'] : 'other',
      start: start,
      end: end,
      active: raw['active'] == true,
      deputy: '${raw['deputy'] ?? ''}',
      deputyExtension: '${raw['deputy_extension'] ?? ''}',
      deputyMobile: '${raw['deputy_mobile'] ?? ''}',
      note: '${raw['note'] ?? ''}',
    );
  }
}

class AwayState {
  const AwayState({this.note, this.canManage = false, this.maxDays = 120});

  final AwayNote? note;

  /// Кадры: могут поставить отметку за другого.
  final bool canManage;
  final int maxDays;
}

class AwayResult {
  const AwayResult({this.ok = false, this.note, this.error, this.problem});

  final bool ok;
  final AwayNote? note;
  final String? error;
  final LoadProblem? problem;
}

Uri _uri(String? employeeId) => Uri.parse(
    '${AppValues.baseUrl}/api/away${employeeId == null ? '' : '/$employeeId'}');

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

Future<AwayState> fetchAway({String? employeeId}) async {
  try {
    final response = await http
        .get(_uri(employeeId), headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return AwayState(
      note: AwayNote.fromJson(body['away']),
      canManage: body['can_manage'] == true,
      maxDays: (body['max_days'] as num?)?.toInt() ?? 120,
    );
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

AwayResult _result(http.Response response) {
  Map<String, dynamic> body = const {};
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) body = decoded;
  } catch (_) {}
  if (response.statusCode == 200 && body['message'] == 'Success') {
    return AwayResult(ok: true, note: AwayNote.fromJson(body['away']));
  }
  final error = body['error'];
  return AwayResult(
      error: error is String ? error : null,
      problem: problemForStatus(response.statusCode));
}

Future<AwayResult> saveAway({
  required String reason,
  required DateTime start,
  required DateTime end,
  String deputy = '',
  String note = '',
  String? employeeId,
}) async {
  try {
    final response = await http
        .put(_uri(employeeId),
            headers: await authHeaders(),
            body: jsonEncode({
              'reason': reason,
              'start': _day(start),
              'end': _day(end),
              if (deputy.isNotEmpty) 'deputy': deputy,
              if (note.isNotEmpty) 'note': note,
            }))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const AwayResult(problem: LoadProblem.denied);
    }
    return _result(response);
  } catch (e) {
    return AwayResult(problem: problemOf(e));
  }
}

Future<AwayResult> clearAway({String? employeeId}) async {
  try {
    final response = await http
        .delete(_uri(employeeId), headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const AwayResult(problem: LoadProblem.denied);
    }
    return _result(response);
  } catch (e) {
    return AwayResult(problem: problemOf(e));
  }
}
