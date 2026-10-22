import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItPerson;
import 'stock_request.dart' show StockLine;

/// Этапы по порядку: дальше «на складе» закупка не идёт.
const purchaseStages = [
  'new',
  'accepted',
  'sourcing',
  'contract',
  'in_transit',
  'delivered'
];

class PurchaseEvent {
  const PurchaseEvent(
      {required this.action,
      this.stage = '',
      this.at,
      this.actor,
      this.comment = ''});

  final String action;
  final String stage;
  final DateTime? at;
  final ItPerson? actor;
  final String comment;

  factory PurchaseEvent.fromJson(Map<String, dynamic> json) => PurchaseEvent(
        action: '${json['action'] ?? ''}',
        stage: '${json['stage'] ?? ''}',
        at: _time(json['at']),
        actor: ItPerson.fromJson(json['actor']),
        comment: '${json['comment'] ?? ''}',
      );
}

class Purchase {
  const Purchase({
    required this.id,
    required this.purpose,
    required this.status,
    this.neededBy,
    this.urgent = false,
    this.author,
    this.assignee,
    this.supplier = '',
    this.eta,
    this.reason = '',
    this.stale = false,
    this.createdAt,
    this.lines = const [],
    this.events = const [],
    this.isAuthor = false,
    this.canAct = false,
    this.canAssign = false,
  });

  final int id;
  final String purpose;

  /// Этап из [purchaseStages] или rejected / cancelled.
  final String status;
  final DateTime? neededBy;
  final bool urgent;
  final ItPerson? author;
  final ItPerson? assignee;
  final String supplier;
  final DateTime? eta;
  final String reason;

  /// Неделю без движения.
  final bool stale;
  final DateTime? createdAt;
  final List<StockLine> lines;
  final List<PurchaseEvent> events;
  final bool isAuthor;
  final bool canAct;

  /// Руководитель ДМТО — может передать другому менеджеру.
  final bool canAssign;

  bool get isOpen =>
      status != 'delivered' && status != 'rejected' && status != 'cancelled';

  /// Номер этапа для полоски прогресса; -1 — отказ или отмена.
  int get stageIndex => purchaseStages.indexOf(status);

  /// Куда можно перевести дальше.
  List<String> get nextStages => stageIndex < 0
      ? const []
      : purchaseStages.sublist(
          (stageIndex + 1).clamp(2, purchaseStages.length));

  /// Когда закупка попала на этап — из истории.
  DateTime? reachedAt(String stage) {
    for (final e in events.reversed) {
      if (e.stage == stage) return e.at;
    }
    return null;
  }

  factory Purchase.fromJson(Map<String, dynamic> json) {
    final lines = json['lines'];
    final events = json['events'];
    DateTime? day(Object? raw) =>
        raw is String ? DateTime.tryParse(raw) : null;
    return Purchase(
      id: (json['id'] as num?)?.toInt() ?? 0,
      purpose: '${json['purpose'] ?? ''}',
      status: '${json['status'] ?? 'new'}',
      neededBy: day(json['needed_by']),
      urgent: json['urgent'] == true,
      author: ItPerson.fromJson(json['author']),
      assignee: ItPerson.fromJson(json['assignee']),
      supplier: '${json['supplier'] ?? ''}',
      eta: day(json['eta']),
      reason: '${json['reason'] ?? ''}',
      stale: json['stale'] == true,
      createdAt: _time(json['created_at']),
      lines: lines is List
          ? lines.map(StockLine.fromJson).whereType<StockLine>().toList()
          : const [],
      events: events is List
          ? events
              .whereType<Map>()
              .map((e) => PurchaseEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      isAuthor: json['is_author'] == true,
      canAct: json['can_act'] == true,
      canAssign: json['can_assign'] == true,
    );
  }
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class PurchaseList {
  const PurchaseList(
      {required this.items,
      this.staff = false,
      this.head = false,
      this.open = const {},
      this.mineOpen = 0});

  final List<Purchase> items;
  final bool staff;
  final bool head;
  final Map<String, int> open;

  /// Сколько открытых у этого менеджера.
  final int mineOpen;

  factory PurchaseList.fromJson(Map<String, dynamic> json) {
    final open = json['open'];
    return PurchaseList(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Purchase.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      staff: json['staff'] == true,
      head: json['head'] == true,
      open: open is Map
          ? {
              for (final e in open.entries)
                if (e.value is num) '${e.key}': (e.value as num).toInt()
            }
          : const {},
      mineOpen: (json['mine_open'] as num?)?.toInt() ?? 0,
    );
  }
}

class PurchaseResult {
  const PurchaseResult({this.item, this.error, this.problem});

  final Purchase? item;
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

Future<PurchaseList> fetchPurchases({bool queue = false}) async =>
    PurchaseList.fromJson(
        await _get('/api/purchases${queue ? '?scope=queue' : ''}'));

Future<Purchase> fetchPurchase(int id) async {
  final body = await _get('/api/purchases/$id');
  return Purchase.fromJson(body['item'] as Map<String, dynamic>);
}

/// Менеджеры ДМТО — кому руководитель может отдать заявку.
Future<List<ItPerson>> fetchPurchaseStaff() async {
  final people = (await _get('/api/purchases/staff'))['people'];
  return people is List
      ? people.map(ItPerson.fromJson).whereType<ItPerson>().toList()
      : const [];
}

Future<PurchaseResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const PurchaseResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return PurchaseResult(
          item: Purchase.fromJson(Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return PurchaseResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return PurchaseResult(problem: problemOf(e));
  }
}

String isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}';

Future<PurchaseResult> createPurchase({
  required String purpose,
  required List<StockLine> lines,
  DateTime? neededBy,
  bool urgent = false,
}) =>
    _post('/api/purchases', {
      'purpose': purpose,
      if (neededBy != null) 'needed_by': isoDay(neededBy),
      if (urgent) 'urgent': true,
      'lines': [
        for (final l in lines)
          {'name': l.name, 'quantity': l.quantity, 'unit': l.unit}
      ],
    });

/// take, assign, stage, reject, cancel, comment.
Future<PurchaseResult> purchaseAction(int id, String action,
        {String comment = '',
        String? stage,
        String? assigneeId,
        String supplier = '',
        DateTime? eta}) =>
    _post('/api/purchases/$id', {
      'action': action,
      if (comment.isNotEmpty) 'comment': comment,
      if (stage != null) 'stage': stage,
      if (assigneeId != null) 'assignee_id': assigneeId,
      if (supplier.isNotEmpty) 'supplier': supplier,
      if (eta != null) 'eta': isoDay(eta),
    });
