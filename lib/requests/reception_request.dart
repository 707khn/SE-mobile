import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'assignment_request.dart' show AssignPerson;

AssignPerson? _person(Object? raw) =>
    raw is Map ? AssignPerson.fromJson(Map<String, dynamic>.from(raw)) : null;

/// Окно приёма. [status]: requested — ждёт приёмную, confirmed — подтверждено.
class ReceptionSlot {
  const ReceptionSlot({
    required this.id,
    required this.startsAt,
    this.minutes = 15,
    this.host,
    this.booked = false,
    this.mine = false,
    this.topic = '',
    this.status,
    this.employee,
  });

  final int id;

  /// Время завода, без пояса — как его открыла приёмная.
  final DateTime startsAt;
  final int minutes;
  final AssignPerson? host;
  final bool booked;
  final bool mine;
  final String topic;
  final String? status;
  final AssignPerson? employee;

  static ReceptionSlot? fromJson(Map<String, dynamic> json) {
    final at = json['starts_at'];
    final startsAt = at is String ? DateTime.tryParse(at) : null;
    if (startsAt == null) return null;
    return ReceptionSlot(
      id: (json['id'] as num?)?.toInt() ?? 0,
      startsAt: startsAt,
      minutes: (json['minutes'] as num?)?.toInt() ?? 15,
      host: _person(json['host']),
      booked: json['booked'] == true,
      mine: json['mine'] == true,
      topic: '${json['topic'] ?? ''}',
      status: json['status'] as String?,
      employee: _person(json['employee']),
    );
  }
}

List<ReceptionSlot> _slots(Object? raw) => ((raw as List?) ?? const [])
    .whereType<Map>()
    .map((e) => ReceptionSlot.fromJson(Map<String, dynamic>.from(e)))
    .whereType<ReceptionSlot>()
    .toList();

class ReceptionCard {
  const ReceptionCard({
    this.manager = false,
    this.host = false,
    this.hosts = const [],
    this.bookings = const [],
    this.free = const [],
  });

  /// Ведёт запись — приёмная.
  final bool manager;

  /// Сам принимает — руководитель.
  final bool host;
  final List<AssignPerson> hosts;
  final List<ReceptionSlot> bookings;
  final List<ReceptionSlot> free;

  factory ReceptionCard.fromJson(Map<String, dynamic> json) => ReceptionCard(
        manager: json['manager'] == true,
        host: json['host'] == true,
        hosts: ((json['hosts'] as List?) ?? const [])
            .map(_person)
            .whereType<AssignPerson>()
            .toList(),
        bookings: _slots(json['bookings']),
        free: _slots(json['free']),
      );
}

class ReceptionResult {
  const ReceptionResult(
      {this.ok = false, this.added, this.error, this.problem});

  final bool ok;
  final int? added;
  final String? error;
  final LoadProblem? problem;
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

String _day(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

Future<Map<String, dynamic>> _get(Uri uri) async {
  try {
    final response = await http
        .get(uri, headers: await authHeaders())
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

Future<ReceptionResult> _send(String method, String path,
    [Map<String, Object?> body = const {}]) async {
  try {
    final headers = await authHeaders();
    final request = method == 'DELETE'
        ? http.delete(_uri(path), headers: headers)
        : http.post(_uri(path), headers: headers, body: jsonEncode(body));
    final response = await request.timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const ReceptionResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if (response.statusCode == 200 || response.statusCode == 201) {
      return ReceptionResult(
          ok: true, added: (parsed['added'] as num?)?.toInt());
    }
    final error = parsed['error'];
    return ReceptionResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return ReceptionResult(problem: problemOf(e));
  }
}

Future<ReceptionCard> fetchReception() async =>
    ReceptionCard.fromJson(await _get(_uri('/api/reception')));

/// День приёма: приёмной — у [hostId] (или у всех), руководителю — свой.
Future<List<ReceptionSlot>> fetchReceptionDesk(DateTime day,
    {String? hostId}) async {
  final body = await _get(_uri('/api/reception/desk').replace(queryParameters: {
    'date': _day(day),
    if (hostId != null && hostId.isNotEmpty) 'host': hostId,
  }));
  return _slots(body['slots']);
}

Future<ReceptionResult> bookReception(int slotId, String topic) =>
    _send('POST', '/api/reception/slots/$slotId/book', {'topic': topic});

Future<ReceptionResult> cancelReception(int slotId) =>
    _send('POST', '/api/reception/slots/$slotId/cancel');

/// Открыть окна: «14:00»–«16:00» шагом [step] минут.
Future<ReceptionResult> openReceptionSlots(
        String hostId, DateTime day, String from, String to, String step) =>
    _send('POST', '/api/reception/slots', {
      'host_id': hostId,
      'date': _day(day),
      'from': from,
      'to': to,
      'step': step,
    });

/// confirm — подтвердить; decline — отказать с [reason].
Future<ReceptionResult> answerReception(int slotId, String action,
        {String? reason}) =>
    _send('POST', '/api/reception/slots/$slotId', {
      'action': action,
      if (reason != null) 'reason': reason,
    });

Future<ReceptionResult> deleteReceptionSlot(int slotId) =>
    _send('DELETE', '/api/reception/slots/$slotId');
