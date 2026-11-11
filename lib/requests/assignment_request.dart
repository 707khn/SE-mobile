import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/iso_day.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'person.dart' show ItPerson;

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

DateTime? _day(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

/// Кому можно поручить — с должностью, чтобы не спутать однофамильцев.
class AssignPerson {
  const AssignPerson(
      {required this.id,
      required this.name,
      this.department = '',
      this.jobTitle = ''});

  final String id;
  final String name;
  final String department;
  final String jobTitle;

  factory AssignPerson.fromJson(Map<String, dynamic> json) => AssignPerson(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        department: '${json['department'] ?? ''}',
        jobTitle: '${json['job_title'] ?? ''}',
      );
}

class AssignmentEvent {
  const AssignmentEvent(
      {required this.action, this.comment = '', this.due, this.at, this.actor});

  final String action;
  final String comment;
  final DateTime? due;
  final DateTime? at;
  final ItPerson? actor;

  factory AssignmentEvent.fromJson(Map<String, dynamic> json) =>
      AssignmentEvent(
        action: '${json['action'] ?? ''}',
        comment: '${json['comment'] ?? ''}',
        due: _day(json['due']),
        at: _time(json['at']),
        actor: ItPerson.fromJson(json['actor']),
      );
}

class Assignment {
  const Assignment({
    required this.id,
    required this.title,
    required this.dueDate,
    this.text = '',
    this.important = false,
    this.status = 'new',
    this.overdue = false,
    this.result = '',
    this.proposedDue,
    this.proposedReason = '',
    this.author,
    this.assignee,
    this.updatedAt,
    this.events = const [],
    this.isAuthor = false,
    this.isAssignee = false,
    this.canRemind = false,
  });

  final int id;
  final String title;
  final String text;
  final bool important;
  final DateTime dueDate;

  /// new, in_progress, done (отчитался), closed (принято), cancelled.
  final String status;
  final bool overdue;
  final String result;

  /// Исполнитель просит перенести срок.
  final DateTime? proposedDue;
  final String proposedReason;
  final ItPerson? author;
  final ItPerson? assignee;
  final DateTime? updatedAt;
  final List<AssignmentEvent> events;
  final bool isAuthor;
  final bool isAssignee;
  final bool canRemind;

  bool get isOpen => status == 'new' || status == 'in_progress';
  bool get isClosed => status == 'closed' || status == 'cancelled';

  factory Assignment.fromJson(Map<String, dynamic> json) {
    final events = json['events'];
    return Assignment(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: '${json['title'] ?? ''}',
      text: '${json['text'] ?? ''}',
      important: json['important'] == true,
      dueDate: _day(json['due_date']) ?? DateTime(2000),
      status: '${json['status'] ?? 'new'}',
      overdue: json['overdue'] == true,
      result: '${json['result'] ?? ''}',
      proposedDue: _day(json['proposed_due']),
      proposedReason: '${json['proposed_reason'] ?? ''}',
      author: ItPerson.fromJson(json['author']),
      assignee: ItPerson.fromJson(json['assignee']),
      updatedAt: _time(json['updated_at']),
      events: events is List
          ? events
              .whereType<Map>()
              .map(
                  (e) => AssignmentEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      isAuthor: json['is_author'] == true,
      isAssignee: json['is_assignee'] == true,
      canRemind: json['can_remind'] == true,
    );
  }
}

class AssignmentCounts {
  const AssignmentCounts(
      {this.mineOpen = 0,
      this.mineOverdue = 0,
      this.givenOpen = 0,
      this.givenOverdue = 0,
      this.givenDone = 0});

  final int mineOpen;
  final int mineOverdue;
  final int givenOpen;
  final int givenOverdue;
  final int givenDone;

  factory AssignmentCounts.fromJson(Object? raw) {
    if (raw is! Map) return const AssignmentCounts();
    int n(String key) => (raw[key] as num?)?.toInt() ?? 0;
    return AssignmentCounts(
      mineOpen: n('mine_open'),
      mineOverdue: n('mine_overdue'),
      givenOpen: n('given_open'),
      givenOverdue: n('given_overdue'),
      givenDone: n('given_done'),
    );
  }
}

class AssignmentList {
  const AssignmentList(
      {required this.items,
      this.canAssign = false,
      this.counts = const AssignmentCounts()});

  final List<Assignment> items;
  final bool canAssign;
  final AssignmentCounts counts;

  factory AssignmentList.fromJson(Map<String, dynamic> json) => AssignmentList(
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Assignment.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        canAssign: json['can_assign'] == true,
        counts: AssignmentCounts.fromJson(json['counts']),
      );
}

class AssignmentResult {
  const AssignmentResult({this.items = const [], this.error, this.problem});

  final List<Assignment> items;
  final String? error;
  final LoadProblem? problem;

  bool get ok => items.isNotEmpty;
  Assignment? get item => items.isEmpty ? null : items.first;
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

Future<AssignmentList> fetchAssignments({bool given = false}) async =>
    AssignmentList.fromJson(
        await _get('/api/assignments${given ? '?scope=given' : ''}'));

Future<Assignment> fetchAssignment(int id) async {
  final body = await _get('/api/assignments/$id');
  return Assignment.fromJson(body['item'] as Map<String, dynamic>);
}

Future<List<AssignPerson>> searchAssignees(String query) async {
  final body = await _get(
      '/api/assignments/people?q=${Uri.encodeQueryComponent(query)}');
  return ((body['people'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => AssignPerson.fromJson(Map<String, dynamic>.from(e)))
      .toList();
}

Future<AssignmentResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const AssignmentResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if (response.statusCode == 200 || response.statusCode == 201) {
      final raw = parsed['items'] is List
          ? parsed['items'] as List
          : [if (parsed['item'] is Map) parsed['item']];
      final items = raw
          .whereType<Map>()
          .map((e) => Assignment.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (items.isNotEmpty) return AssignmentResult(items: items);
    }
    final error = parsed['error'];
    return AssignmentResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return AssignmentResult(problem: problemOf(e));
  }
}

Future<AssignmentResult> createAssignments({
  required String title,
  required DateTime dueDate,
  required List<String> assigneeIds,
  String text = '',
  bool important = false,
}) =>
    _post('/api/assignments', {
      'title': title,
      if (text.isNotEmpty) 'text': text,
      'due_date': isoDay(dueDate),
      if (important) 'important': true,
      'assignee_ids': assigneeIds,
    });

/// accept, done, extend, close, return, extend_ok, extend_no, cancel,
/// remind, comment.
Future<AssignmentResult> assignmentAction(int id, String action,
        {String comment = '', DateTime? dueDate}) =>
    _post('/api/assignments/$id', {
      'action': action,
      if (comment.isNotEmpty) 'comment': comment,
      if (dueDate != null) 'due_date': isoDay(dueDate),
    });
