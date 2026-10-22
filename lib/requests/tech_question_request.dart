import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItEvent, ItPerson;

const techQuestionKinds = ['drawing', 'process', 'material', 'other'];

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class TechQuestion {
  const TechQuestion({
    required this.id,
    required this.kind,
    required this.product,
    required this.text,
    this.document = '',
    this.operation = '',
    this.urgent = false,
    this.status = 'new',
    this.decision = '',
    this.author,
    this.assignee,
    this.createdAt,
    this.events = const [],
    this.isAuthor = false,
    this.canAnswer = false,
  });

  final int id;
  final String kind;
  final String product;
  final String document;
  final String operation;
  final String text;
  final bool urgent;

  /// new, in_work, answered, closed.
  final String status;
  final String decision;
  final ItPerson? author;
  final ItPerson? assignee;
  final DateTime? createdAt;
  final List<ItEvent> events;
  final bool isAuthor;
  final bool canAnswer;

  /// «ЧТ 7.312.001, оп. 015».
  String get where => [
        if (document.isNotEmpty) document,
        if (operation.isNotEmpty) 'оп. $operation',
      ].join(', ');

  factory TechQuestion.fromJson(Map<String, dynamic> json) {
    final events = json['events'];
    return TechQuestion(
      id: (json['id'] as num?)?.toInt() ?? 0,
      kind: '${json['kind'] ?? 'other'}',
      product: '${json['product'] ?? ''}',
      document: '${json['document'] ?? ''}',
      operation: '${json['operation'] ?? ''}',
      text: '${json['text'] ?? ''}',
      urgent: json['urgent'] == true,
      status: '${json['status'] ?? 'new'}',
      decision: '${json['decision'] ?? ''}',
      author: ItPerson.fromJson(json['author']),
      assignee: ItPerson.fromJson(json['assignee']),
      createdAt: _time(json['created_at']),
      events: events is List
          ? events
              .whereType<Map>()
              .map((e) => ItEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      isAuthor: json['is_author'] == true,
      canAnswer: json['can_answer'] == true,
    );
  }
}

class TechQuestionList {
  const TechQuestionList(
      {required this.items,
      this.staff = false,
      this.history = false,
      this.waiting = 0});

  final List<TechQuestion> items;
  final bool staff;

  /// Может искать решения по изделию.
  final bool history;
  final int waiting;

  factory TechQuestionList.fromJson(Map<String, dynamic> json) =>
      TechQuestionList(
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => TechQuestion.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        staff: json['staff'] == true,
        history: json['history'] == true,
        waiting: (json['waiting'] as num?)?.toInt() ?? 0,
      );
}

class TechQuestionResult {
  const TechQuestionResult({this.item, this.error, this.problem});

  final TechQuestion? item;
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

Future<TechQuestionList> fetchTechQuestions(
    {bool queue = false, String product = ''}) async {
  final query = product.isNotEmpty
      ? '?product=${Uri.encodeQueryComponent(product)}'
      : (queue ? '?scope=queue' : '');
  return TechQuestionList.fromJson(await _get('/api/tech-questions$query'));
}

Future<TechQuestion> fetchTechQuestion(int id) async {
  final body = await _get('/api/tech-questions/$id');
  return TechQuestion.fromJson(body['item'] as Map<String, dynamic>);
}

/// Изделия, по которым уже спрашивали.
Future<List<String>> suggestTechProducts(String query) async {
  final body = await _get(
      '/api/tech-questions/products?q=${Uri.encodeQueryComponent(query)}');
  return ((body['products'] as List?) ?? const []).whereType<String>().toList();
}

Future<TechQuestionResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const TechQuestionResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return TechQuestionResult(
          item:
              TechQuestion.fromJson(Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return TechQuestionResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return TechQuestionResult(problem: problemOf(e));
  }
}

Future<TechQuestionResult> askTechQuestion({
  required String kind,
  required String product,
  required String text,
  String document = '',
  String operation = '',
  bool urgent = false,
}) =>
    _post('/api/tech-questions', {
      'kind': kind,
      'product': product,
      'text': text,
      if (document.isNotEmpty) 'document': document,
      if (operation.isNotEmpty) 'operation': operation,
      if (urgent) 'urgent': true,
    });

/// take, answer, clarify, close, comment.
Future<TechQuestionResult> techQuestionAction(int id, String action,
        {String text = ''}) =>
    _post('/api/tech-questions/$id', {
      'action': action,
      if (text.isNotEmpty) 'text': text,
    });
