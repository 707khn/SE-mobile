import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItPerson;
import 'stock_request.dart' show StockLine;

class MaterialPassEvent {
  const MaterialPassEvent(
      {required this.action, this.at, this.actor, this.comment = ''});

  final String action;
  final DateTime? at;
  final ItPerson? actor;
  final String comment;

  factory MaterialPassEvent.fromJson(Map<String, dynamic> json) =>
      MaterialPassEvent(
        action: '${json['action'] ?? ''}',
        at: _time(json['at']),
        actor: ItPerson.fromJson(json['actor']),
        comment: '${json['comment'] ?? ''}',
      );
}

class MaterialPass {
  const MaterialPass({
    required this.id,
    required this.purpose,
    required this.carrier,
    required this.exitDate,
    required this.status,
    this.vehicle = '',
    this.expired = false,
    this.code,
    this.author,
    this.approver,
    this.guard,
    this.reason = '',
    this.createdAt,
    this.releasedAt,
    this.lines = const [],
    this.events = const [],
    this.isAuthor = false,
    this.canApprove = false,
    this.canRelease = false,
  });

  final int id;
  final String purpose;
  final String carrier;
  final String vehicle;

  /// День выезда — только дата, без часового пояса.
  final DateTime exitDate;

  /// pending, approved, rejected, released, held, cancelled.
  final String status;

  /// Согласован или ждёт, а день выезда прошёл.
  final bool expired;

  /// Четыре цифры для сверки на КПП; в списках сервер его не отдаёт.
  final String? code;
  final ItPerson? author;
  final ItPerson? approver;
  final ItPerson? guard;
  final String reason;
  final DateTime? createdAt;
  final DateTime? releasedAt;
  final List<StockLine> lines;
  final List<MaterialPassEvent> events;
  final bool isAuthor;
  final bool canApprove;
  final bool canRelease;

  bool get isOpen => !expired && (status == 'pending' || status == 'approved');

  /// Что показывать в чипе: просроченный — отдельным статусом.
  String get shownStatus => expired ? 'expired' : status;

  factory MaterialPass.fromJson(Map<String, dynamic> json) {
    final lines = json['lines'];
    final events = json['events'];
    final code = json['code'];
    return MaterialPass(
      id: (json['id'] as num?)?.toInt() ?? 0,
      purpose: '${json['purpose'] ?? ''}',
      carrier: '${json['carrier'] ?? ''}',
      vehicle: '${json['vehicle'] ?? ''}',
      exitDate: DateTime.tryParse('${json['exit_date']}') ?? DateTime(2000),
      status: '${json['status'] ?? 'pending'}',
      expired: json['expired'] == true,
      code: code is String && code.isNotEmpty ? code : null,
      author: ItPerson.fromJson(json['author']),
      approver: ItPerson.fromJson(json['approver']),
      guard: ItPerson.fromJson(json['guard']),
      reason: '${json['reason'] ?? ''}',
      createdAt: _time(json['created_at']),
      releasedAt: _time(json['released_at']),
      lines: lines is List
          ? lines.map(StockLine.fromJson).whereType<StockLine>().toList()
          : const [],
      events: events is List
          ? events
              .whereType<Map>()
              .map((e) =>
                  MaterialPassEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      isAuthor: json['is_author'] == true,
      canApprove: json['can_approve'] == true,
      canRelease: json['can_release'] == true,
    );
  }
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class MaterialPassList {
  const MaterialPassList(
      {required this.items,
      this.approver = false,
      this.guard = false,
      this.pending = 0});

  final List<MaterialPass> items;
  final bool approver;
  final bool guard;

  /// Сколько ждут согласования — руководителю на вкладку.
  final int pending;

  factory MaterialPassList.fromJson(Map<String, dynamic> json) {
    final roles = json['roles'];
    return MaterialPassList(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => MaterialPass.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      approver: roles is Map && roles['approver'] == true,
      guard: roles is Map && roles['guard'] == true,
      pending: (json['pending'] as num?)?.toInt() ?? 0,
    );
  }
}

class MaterialPassResult {
  const MaterialPassResult({this.item, this.error, this.problem});

  final MaterialPass? item;
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

/// mine, approve или gate.
Future<MaterialPassList> fetchMaterialPasses({String scope = 'mine'}) async =>
    MaterialPassList.fromJson(await _get(
        '/api/material-passes${scope == 'mine' ? '' : '?scope=$scope'}'));

Future<MaterialPass> fetchMaterialPass(int id) async {
  final body = await _get('/api/material-passes/$id');
  return MaterialPass.fromJson(body['item'] as Map<String, dynamic>);
}

Future<MaterialPassResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const MaterialPassResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return MaterialPassResult(
          item: MaterialPass.fromJson(Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return MaterialPassResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return MaterialPassResult(problem: problemOf(e));
  }
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

Future<MaterialPassResult> createMaterialPass({
  required String purpose,
  required String carrier,
  required DateTime exitDate,
  required List<StockLine> lines,
  String vehicle = '',
}) =>
    _post('/api/material-passes', {
      'purpose': purpose,
      'carrier': carrier,
      if (vehicle.isNotEmpty) 'vehicle': vehicle,
      'exit_date': _isoDate(exitDate),
      'lines': [
        for (final l in lines)
          {'name': l.name, 'quantity': l.quantity, 'unit': l.unit}
      ],
    });

/// approve, reject, release, hold, cancel, comment.
Future<MaterialPassResult> materialPassAction(int id, String action,
        {String comment = ''}) =>
    _post('/api/material-passes/$id', {
      'action': action,
      if (comment.isNotEmpty) 'comment': comment,
    });
