import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'assignment_request.dart' show AssignPerson;
import 'it_request.dart' show ItEvent, ItPerson;

const workPermitKinds = [
  'fire',
  'height',
  'electrical',
  'gas',
  'confined',
  'earth',
  'other'
];

const workPermitOpen = {'pending', 'approved', 'open'};

/// Время предприятия приходит без пояса: «2030-01-15T09:00».
DateTime? _plantTime(Object? raw) =>
    raw is String ? DateTime.tryParse(raw) : null;

String permitTime(DateTime moment) =>
    '${moment.year.toString().padLeft(4, '0')}-'
    '${moment.month.toString().padLeft(2, '0')}-'
    '${moment.day.toString().padLeft(2, '0')}T'
    '${moment.hour.toString().padLeft(2, '0')}:'
    '${moment.minute.toString().padLeft(2, '0')}';

List<String> _strings(Object? raw) =>
    raw is List ? raw.whereType<String>().toList() : const [];

class WorkPermit {
  const WorkPermit({
    required this.id,
    required this.kind,
    required this.place,
    required this.work,
    this.startsAt,
    this.endsAt,
    this.members = const [],
    this.measures = const [],
    this.status = 'pending',
    this.reason = '',
    this.overdue = false,
    this.expired = false,
    this.issuer,
    this.responsible,
    this.performer,
    this.admitter,
    this.approver,
    this.events = const [],
    this.canApprove = false,
    this.canAdmit = false,
    this.canClose = false,
    this.canStop = false,
    this.canCancel = false,
    this.canComment = false,
  });

  final int id;
  final String kind;
  final String place;
  final String work;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final List<String> members;
  final List<String> measures;

  /// pending, approved, open, closed, rejected, cancelled, stopped.
  final String status;
  final String reason;

  /// Работы идут, а срок наряда прошёл.
  final bool overdue;

  /// Не допущен, а срок прошёл.
  final bool expired;
  final ItPerson? issuer;
  final ItPerson? responsible;
  final ItPerson? performer;
  final ItPerson? admitter;
  final ItPerson? approver;
  final List<ItEvent> events;
  final bool canApprove;
  final bool canAdmit;
  final bool canClose;
  final bool canStop;
  final bool canCancel;
  final bool canComment;

  bool get isOpen => workPermitOpen.contains(status);

  factory WorkPermit.fromJson(Map<String, dynamic> json) {
    final events = json['events'];
    return WorkPermit(
      id: (json['id'] as num?)?.toInt() ?? 0,
      kind: '${json['kind'] ?? 'other'}',
      place: '${json['place'] ?? ''}',
      work: '${json['work'] ?? ''}',
      startsAt: _plantTime(json['starts_at']),
      endsAt: _plantTime(json['ends_at']),
      members: _strings(json['members']),
      measures: _strings(json['measures']),
      status: '${json['status'] ?? 'pending'}',
      reason: '${json['reason'] ?? ''}',
      overdue: json['overdue'] == true,
      expired: json['expired'] == true,
      issuer: ItPerson.fromJson(json['issuer']),
      responsible: ItPerson.fromJson(json['responsible']),
      performer: ItPerson.fromJson(json['performer']),
      admitter: ItPerson.fromJson(json['admitter']),
      approver: ItPerson.fromJson(json['approver']),
      events: events is List
          ? events
              .whereType<Map>()
              .map((e) => ItEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      canApprove: json['can_approve'] == true,
      canAdmit: json['can_admit'] == true,
      canClose: json['can_close'] == true,
      canStop: json['can_stop'] == true,
      canCancel: json['can_cancel'] == true,
      canComment: json['can_comment'] == true,
    );
  }
}

class WorkPermitList {
  const WorkPermitList({
    required this.items,
    this.canIssue = false,
    this.safety = false,
    this.board = false,
    this.waiting = 0,
    this.measures = const {},
  });

  final List<WorkPermit> items;
  final bool canIssue;

  /// Служба БиОТ: очередь на согласование.
  final bool safety;

  /// Видит доску «Сейчас идут».
  final bool board;
  final int waiting;

  /// Меры безопасности по виду работ — подсказка в форме.
  final Map<String, List<String>> measures;

  factory WorkPermitList.fromJson(Map<String, dynamic> json) {
    final measures = json['measures'];
    return WorkPermitList(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => WorkPermit.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      canIssue: json['can_issue'] == true,
      safety: json['safety'] == true,
      board: json['board'] == true,
      waiting: (json['waiting'] as num?)?.toInt() ?? 0,
      measures: measures is Map
          ? {
              for (final entry in measures.entries)
                '${entry.key}': _strings(entry.value)
            }
          : const {},
    );
  }
}

class WorkPermitResult {
  const WorkPermitResult({this.item, this.error, this.problem});

  final WorkPermit? item;
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

/// [scope]: null — мои, 'board' — сейчас идут, 'queue' — ждут БиОТ.
Future<WorkPermitList> fetchWorkPermits({String? scope}) async =>
    WorkPermitList.fromJson(
        await _get('/api/permits${scope == null ? '' : '?scope=$scope'}'));

Future<WorkPermit> fetchWorkPermit(int id) async {
  final body = await _get('/api/permits/$id');
  return WorkPermit.fromJson(body['item'] as Map<String, dynamic>);
}

Future<List<AssignPerson>> searchPermitPeople(String query) async {
  final body =
      await _get('/api/permits/people?q=${Uri.encodeQueryComponent(query)}');
  return ((body['people'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => AssignPerson.fromJson(Map<String, dynamic>.from(e)))
      .toList();
}

Future<WorkPermitResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const WorkPermitResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return WorkPermitResult(
          item: WorkPermit.fromJson(Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return WorkPermitResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return WorkPermitResult(problem: problemOf(e));
  }
}

Future<WorkPermitResult> issueWorkPermit({
  required String kind,
  required String place,
  required String work,
  required DateTime startsAt,
  required DateTime endsAt,
  required String performerId,
  String responsibleId = '',
  String admitterId = '',
  List<String> members = const [],
  List<String> measures = const [],
}) =>
    _post('/api/permits', {
      'kind': kind,
      'place': place,
      'work': work,
      'starts_at': permitTime(startsAt),
      'ends_at': permitTime(endsAt),
      'performer_id': performerId,
      if (responsibleId.isNotEmpty) 'responsible_id': responsibleId,
      if (admitterId.isNotEmpty) 'admitter_id': admitterId,
      'members': members,
      'measures': measures,
    });

/// approve, reject, admit, close, stop, cancel, comment.
Future<WorkPermitResult> workPermitAction(int id, String action,
        {String text = ''}) =>
    _post('/api/permits/$id', {
      'action': action,
      if (text.isNotEmpty) 'text': text,
    });
