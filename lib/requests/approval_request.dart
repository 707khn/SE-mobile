import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

const approvalKinds = ['contract', 'memo', 'other'];

/// Человек в листе: автор или согласующий — с должностью, чтобы в маршруте
/// было видно «начальник юридического отдела», а не только фамилию.
class ApprovalPerson {
  const ApprovalPerson(
      {required this.id,
      required this.name,
      this.title = '',
      this.department = ''});

  final String id;
  final String name;
  final String title;
  final String department;

  /// «Иванов И.» — для строк списка.
  String get short {
    final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length < 2) return name;
    return '${parts[0]} ${parts[1][0]}.';
  }

  static ApprovalPerson? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = '${json['id'] ?? ''}';
    if (id.isEmpty) return null;
    return ApprovalPerson(
      id: id,
      name: '${json['name'] ?? id}',
      title: '${json['title'] ?? ''}',
      department: '${json['department'] ?? ''}',
    );
  }

  @override
  bool operator ==(Object other) => other is ApprovalPerson && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

class ApprovalStep {
  const ApprovalStep(
      {required this.position,
      required this.person,
      this.decision = 'pending',
      this.comment = '',
      this.decidedAt});

  final int position;
  final ApprovalPerson person;

  /// pending, approved, returned.
  final String decision;
  final String comment;
  final DateTime? decidedAt;

  static ApprovalStep? fromJson(Map<String, dynamic> json) {
    final person = ApprovalPerson.fromJson(json['person']);
    if (person == null) return null;
    return ApprovalStep(
      position: (json['position'] as num?)?.toInt() ?? 0,
      person: person,
      decision: '${json['decision'] ?? 'pending'}',
      comment: '${json['comment'] ?? ''}',
      decidedAt: _time(json['decided_at']),
    );
  }
}

class ApprovalEvent {
  const ApprovalEvent(
      {required this.action, this.at, this.actor, this.comment = ''});

  final String action;
  final DateTime? at;
  final ApprovalPerson? actor;
  final String comment;

  factory ApprovalEvent.fromJson(Map<String, dynamic> json) => ApprovalEvent(
        action: '${json['action'] ?? ''}',
        at: _time(json['at']),
        actor: ApprovalPerson.fromJson(json['actor']),
        comment: '${json['comment'] ?? ''}',
      );
}

class Approval {
  const Approval({
    required this.id,
    required this.kind,
    required this.title,
    required this.summary,
    required this.status,
    this.docNumber = '',
    this.counterparty = '',
    this.amount = '',
    this.author,
    this.current,
    this.stepSince,
    this.createdAt,
    this.steps = const [],
    this.events = const [],
    this.myTurn = false,
    this.isAuthor = false,
    this.canRemind = false,
  });

  final int id;
  final String kind;
  final String title;
  final String docNumber;
  final String counterparty;
  final String amount;
  final String summary;

  /// on_route, approved, returned, cancelled.
  final String status;
  final ApprovalPerson? author;

  /// У кого документ сейчас; null — маршрут закончен.
  final ApprovalPerson? current;
  final DateTime? stepSince;
  final DateTime? createdAt;
  final List<ApprovalStep> steps;
  final List<ApprovalEvent> events;
  final bool myTurn;
  final bool isAuthor;
  final bool canRemind;

  bool get isOpen => status == 'on_route' || status == 'returned';

  int get approvedCount => steps.where((s) => s.decision == 'approved').length;

  /// Сколько часов лежит у текущего согласующего.
  double? waitingHours(DateTime now) {
    if (status != 'on_route' || stepSince == null) return null;
    return now.difference(stepSince!).inMinutes / 60;
  }

  /// Дольше двух суток у одного человека — «завис».
  bool isStale(DateTime now) => (waitingHours(now) ?? 0) >= 48;

  factory Approval.fromJson(Map<String, dynamic> json) {
    List<T> list<T>(Object? raw, T? Function(Map<String, dynamic>) parse) =>
        raw is List
            ? raw
                .whereType<Map>()
                .map((e) => parse(Map<String, dynamic>.from(e)))
                .whereType<T>()
                .toList()
            : <T>[];
    return Approval(
      id: (json['id'] as num?)?.toInt() ?? 0,
      kind: '${json['kind'] ?? 'contract'}',
      title: '${json['title'] ?? ''}',
      docNumber: '${json['doc_number'] ?? ''}',
      counterparty: '${json['counterparty'] ?? ''}',
      amount: '${json['amount'] ?? ''}',
      summary: '${json['summary'] ?? ''}',
      status: '${json['status'] ?? 'on_route'}',
      author: ApprovalPerson.fromJson(json['author']),
      current: ApprovalPerson.fromJson(json['current']),
      stepSince: _time(json['step_since']),
      createdAt: _time(json['created_at']),
      steps: list(json['steps'], ApprovalStep.fromJson),
      events: list(json['events'], ApprovalEvent.fromJson),
      myTurn: json['my_turn'] == true,
      isAuthor: json['is_author'] == true,
      canRemind: json['can_remind'] == true,
    );
  }
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class ApprovalList {
  const ApprovalList({required this.items, this.todo = 0});

  final List<Approval> items;

  /// Сколько ждут подписи того, кто смотрит.
  final int todo;

  factory ApprovalList.fromJson(Map<String, dynamic> json) => ApprovalList(
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Approval.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        todo: (json['todo'] as num?)?.toInt() ?? 0,
      );
}

class ApprovalResult {
  const ApprovalResult({this.item, this.error, this.problem});

  final Approval? item;
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

Future<ApprovalList> fetchApprovals() async =>
    ApprovalList.fromJson(await _get('/api/approvals'));

Future<Approval> fetchApproval(int id) async {
  final body = await _get('/api/approvals/$id');
  return Approval.fromJson(body['item'] as Map<String, dynamic>);
}

List<ApprovalPerson> _people(Object? raw) => raw is List
    ? raw.map(ApprovalPerson.fromJson).whereType<ApprovalPerson>().toList()
    : const [];

/// Обычный маршрут для вида документа.
Future<List<ApprovalPerson>> fetchSuggestedRoute(String kind) async =>
    _people((await _get('/api/approvals/route?kind=$kind'))['steps']);

Future<List<ApprovalPerson>> searchApprovers(String query) async =>
    _people((await _get(
            '/api/approvals/people?q=${Uri.encodeQueryComponent(query)}'))[
        'people']);

Future<ApprovalResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const ApprovalResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return ApprovalResult(
          item: Approval.fromJson(Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return ApprovalResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return ApprovalResult(problem: problemOf(e));
  }
}

Future<ApprovalResult> createApproval({
  required String kind,
  required String title,
  required String summary,
  required List<String> route,
  String docNumber = '',
  String counterparty = '',
  String amount = '',
}) =>
    _post('/api/approvals', {
      'kind': kind,
      'title': title,
      'summary': summary,
      'route': route,
      if (docNumber.isNotEmpty) 'doc_number': docNumber,
      if (counterparty.isNotEmpty) 'counterparty': counterparty,
      if (amount.isNotEmpty) 'amount': amount,
    });

/// approve, return, resubmit, cancel, remind, comment.
Future<ApprovalResult> approvalAction(int id, String action,
        {String comment = ''}) =>
    _post('/api/approvals/$id', {
      'action': action,
      if (comment.isNotEmpty) 'comment': comment,
    });
