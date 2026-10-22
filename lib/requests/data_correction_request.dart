import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItEvent, ItPerson;

const dataCorrectionKinds = [
  'name',
  'job',
  'department',
  'contacts',
  'documents',
  'other'
];

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class DataCorrection {
  const DataCorrection({
    required this.id,
    required this.kind,
    required this.requested,
    this.current = '',
    this.comment = '',
    this.status = 'new',
    this.resolution = '',
    this.author,
    this.assignee,
    this.createdAt,
    this.events = const [],
    this.isAuthor = false,
    this.canHandle = false,
  });

  final int id;
  final String kind;

  /// Что записано сейчас — на момент просьбы.
  final String current;

  /// Как правильно.
  final String requested;
  final String comment;

  /// new, in_work, done, rejected, cancelled.
  final String status;
  final String resolution;
  final ItPerson? author;
  final ItPerson? assignee;
  final DateTime? createdAt;
  final List<ItEvent> events;
  final bool isAuthor;
  final bool canHandle;

  bool get isOpen => status == 'new' || status == 'in_work';

  factory DataCorrection.fromJson(Map<String, dynamic> json) {
    final events = json['events'];
    return DataCorrection(
      id: (json['id'] as num?)?.toInt() ?? 0,
      kind: '${json['kind'] ?? 'other'}',
      current: '${json['current'] ?? ''}',
      requested: '${json['requested'] ?? ''}',
      comment: '${json['comment'] ?? ''}',
      status: '${json['status'] ?? 'new'}',
      resolution: '${json['resolution'] ?? ''}',
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
      canHandle: json['can_handle'] == true,
    );
  }
}

class DataCorrectionList {
  const DataCorrectionList(
      {required this.items,
      this.staff = false,
      this.waiting = 0,
      this.profile = const {}});

  final List<DataCorrection> items;

  /// Отдел кадров: есть очередь.
  final bool staff;
  final int waiting;

  /// Что записано о самом человеке: name, job, department.
  final Map<String, String> profile;

  factory DataCorrectionList.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'];
    return DataCorrectionList(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => DataCorrection.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      staff: json['staff'] == true,
      waiting: (json['waiting'] as num?)?.toInt() ?? 0,
      profile: profile is Map
          ? {
              for (final entry in profile.entries)
                if (entry.value is String) '${entry.key}': entry.value as String
            }
          : const {},
    );
  }
}

class DataCorrectionResult {
  const DataCorrectionResult({this.item, this.error, this.problem});

  final DataCorrection? item;
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

Future<DataCorrectionList> fetchDataCorrections({bool queue = false}) async =>
    DataCorrectionList.fromJson(
        await _get('/api/data-corrections${queue ? '?scope=queue' : ''}'));

Future<DataCorrection> fetchDataCorrection(int id) async {
  final body = await _get('/api/data-corrections/$id');
  return DataCorrection.fromJson(body['item'] as Map<String, dynamic>);
}

Future<DataCorrectionResult> _post(
    String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const DataCorrectionResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return DataCorrectionResult(
          item: DataCorrection.fromJson(
              Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return DataCorrectionResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return DataCorrectionResult(problem: problemOf(e));
  }
}

Future<DataCorrectionResult> askDataCorrection({
  required String kind,
  required String requested,
  String comment = '',
}) =>
    _post('/api/data-corrections', {
      'kind': kind,
      'requested': requested,
      if (comment.isNotEmpty) 'comment': comment,
    });

/// take, done, reject, cancel, comment.
Future<DataCorrectionResult> dataCorrectionAction(int id, String action,
        {String text = ''}) =>
    _post('/api/data-corrections/$id', {
      'action': action,
      if (text.isNotEmpty) 'text': text,
    });
