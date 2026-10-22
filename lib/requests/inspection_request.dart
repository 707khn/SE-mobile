import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItPerson;

/// Партия «в работе» у ОТК или ВП.
const inspectionInFlight = {
  'waiting_otk',
  'checking_otk',
  'waiting_vp',
  'checking_vp'
};

class InspectionEvent {
  const InspectionEvent(
      {required this.action,
      this.stage = '',
      this.at,
      this.actor,
      this.comment = ''});

  final String action;

  /// otk или vp: «принято ОТК» и «принято ВП» — разные строки истории.
  final String stage;
  final DateTime? at;
  final ItPerson? actor;
  final String comment;

  factory InspectionEvent.fromJson(Map<String, dynamic> json) =>
      InspectionEvent(
        action: '${json['action'] ?? ''}',
        stage: '${json['stage'] ?? ''}',
        at: _time(json['at']),
        actor: ItPerson.fromJson(json['actor']),
        comment: '${json['comment'] ?? ''}',
      );
}

class Inspection {
  const Inspection({
    required this.id,
    required this.product,
    required this.quantity,
    required this.place,
    required this.status,
    this.orderNo = '',
    this.note = '',
    this.needsVp = false,
    this.stage,
    this.author,
    this.otk,
    this.vp,
    this.returnReason = '',
    this.returns = 0,
    this.stageSince,
    this.createdAt,
    this.events = const [],
    this.canAct = false,
  });

  final int id;
  final String product;
  final int quantity;
  final String orderNo;
  final String place;
  final String note;
  final bool needsVp;
  final String status;

  /// otk, vp или null, когда партия уже ни у кого.
  final String? stage;
  final ItPerson? author;
  final ItPerson? otk;
  final ItPerson? vp;
  final String returnReason;
  final int returns;

  /// С какого момента ждёт на текущем шаге.
  final DateTime? stageSince;
  final DateTime? createdAt;
  final List<InspectionEvent> events;

  /// Смотрящий проверяет на текущем шаге — ему «Взять», «Принять», «Вернуть».
  final bool canAct;

  bool get inFlight => inspectionInFlight.contains(status);
  bool get isOpen => inFlight || status == 'returned';

  /// Сколько часов ждёт на этом шаге — для «ждёт 3 ч» в очереди.
  double? waitingHours(DateTime now) {
    if (!inFlight || stageSince == null) return null;
    return now.difference(stageSince!).inMinutes / 60;
  }

  factory Inspection.fromJson(Map<String, dynamic> json) {
    final events = json['events'];
    final stage = json['stage'];
    return Inspection(
      id: (json['id'] as num?)?.toInt() ?? 0,
      product: '${json['product'] ?? ''}',
      quantity: (json['quantity'] as num?)?.toInt() ?? 0,
      orderNo: '${json['order_no'] ?? ''}',
      place: '${json['place'] ?? ''}',
      note: '${json['note'] ?? ''}',
      needsVp: json['needs_vp'] == true,
      status: '${json['status'] ?? 'waiting_otk'}',
      stage: stage is String && stage.isNotEmpty ? stage : null,
      author: ItPerson.fromJson(json['author']),
      otk: ItPerson.fromJson(json['otk']),
      vp: ItPerson.fromJson(json['vp']),
      returnReason: '${json['return_reason'] ?? ''}',
      returns: (json['returns'] as num?)?.toInt() ?? 0,
      stageSince: _time(json['stage_since']),
      createdAt: _time(json['created_at']),
      events: events is List
          ? events
              .whereType<Map>()
              .map((e) =>
                  InspectionEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      canAct: json['can_act'] == true,
    );
  }
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class InspectionList {
  const InspectionList(
      {required this.items,
      this.staff = false,
      this.otk = false,
      this.vp = false,
      this.open = const {}});

  final List<Inspection> items;

  /// Видит очередь: ОТК, ВП или начальник ОП.
  final bool staff;
  final bool otk;
  final bool vp;

  /// Сколько партий на каждом шаге.
  final Map<String, int> open;

  factory InspectionList.fromJson(Map<String, dynamic> json) {
    final roles = json['roles'];
    final open = json['open'];
    return InspectionList(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Inspection.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      staff: json['staff'] == true,
      otk: roles is Map && roles['otk'] == true,
      vp: roles is Map && roles['vp'] == true,
      open: open is Map
          ? {
              for (final e in open.entries)
                if (e.value is num) '${e.key}': (e.value as num).toInt()
            }
          : const {},
    );
  }
}

class InspectionResult {
  const InspectionResult({this.item, this.error, this.problem});

  final Inspection? item;
  final String? error;
  final LoadProblem? problem;

  bool get ok => item != null;
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

Future<InspectionList> fetchInspections({bool queue = false}) async {
  try {
    final response = await http
        .get(_uri('/api/inspections${queue ? '?scope=queue' : ''}'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    return InspectionList.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

Future<Inspection> fetchInspection(int id) async {
  try {
    final response = await http
        .get(_uri('/api/inspections/$id'), headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return Inspection.fromJson(body['item'] as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

Future<InspectionResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const InspectionResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return InspectionResult(
          item: Inspection.fromJson(Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return InspectionResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return InspectionResult(problem: problemOf(e));
  }
}

Future<InspectionResult> createInspection({
  required String product,
  required int quantity,
  required String place,
  String orderNo = '',
  String note = '',
  bool needsVp = false,
}) =>
    _post('/api/inspections', {
      'product': product,
      'quantity': quantity,
      'place': place,
      if (orderNo.isNotEmpty) 'order_no': orderNo,
      if (note.isNotEmpty) 'note': note,
      'needs_vp': needsVp,
    });

/// take, accept, return, resubmit, cancel, comment.
Future<InspectionResult> inspectionAction(int id, String action,
        {String comment = ''}) =>
    _post('/api/inspections/$id', {
      'action': action,
      if (comment.isNotEmpty) 'comment': comment,
    });
