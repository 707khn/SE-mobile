import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItEvent, ItPerson;

const stockWarehouses = <int>[1, 2, 3];

/// Единицы — те же, что принимает сервер.
const stockUnits = <String>[
  'шт', 'кг', 'г', 'л', 'м', 'м²', 'м³', 'пар', 'упак', 'компл', 'рул', 'т'
];

const stockOpenStatuses = {'new', 'in_progress', 'ready'};

class StockLine {
  const StockLine(
      {this.id = 0,
      required this.name,
      required this.quantity,
      this.unit = 'шт',
      this.missing = false});

  final int id;
  final String name;
  final double quantity;
  final String unit;

  /// Кладовщик отметил, что этого нет.
  final bool missing;

  /// 5.0 → «5», 2.5 → «2,5».
  String get amount {
    final text = quantity == quantity.roundToDouble()
        ? quantity.toInt().toString()
        : quantity.toString();
    return '${text.replaceAll('.', ',')} $unit';
  }

  static StockLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return StockLine(
      id: (raw['id'] as num?)?.toInt() ?? 0,
      name: '${raw['name'] ?? ''}',
      quantity: (raw['quantity'] as num?)?.toDouble() ?? 0,
      unit: '${raw['unit'] ?? 'шт'}',
      missing: raw['missing'] == true,
    );
  }
}

class StockRequest {
  const StockRequest({
    required this.id,
    required this.purpose,
    required this.status,
    this.warehouse,
    this.lines = const [],
    this.author,
    this.assignee,
    this.resolution = '',
    this.createdAt,
    this.closedAt,
    this.events = const [],
    this.canAct = false,
  });

  final int id;
  final int? warehouse;
  final String purpose;
  final String status;
  final List<StockLine> lines;
  final ItPerson? author;
  final ItPerson? assignee;
  final String resolution;
  final DateTime? createdAt;
  final DateTime? closedAt;
  final List<ItEvent> events;

  /// Смотрит склад: ему «Взять», «Собрано», «Выдано». Решает сервер.
  final bool canAct;

  bool get isOpen => stockOpenStatuses.contains(status);
  int get missingCount => lines.where((l) => l.missing).length;

  factory StockRequest.fromJson(Map<String, dynamic> json) {
    final lines = json['lines'];
    final events = json['events'];
    return StockRequest(
      id: (json['id'] as num?)?.toInt() ?? 0,
      warehouse: (json['warehouse'] as num?)?.toInt(),
      purpose: '${json['purpose'] ?? ''}',
      status: '${json['status'] ?? 'new'}',
      lines: lines is List
          ? lines.map(StockLine.fromJson).whereType<StockLine>().toList()
          : const [],
      author: ItPerson.fromJson(json['author']),
      assignee: ItPerson.fromJson(json['assignee']),
      resolution: '${json['resolution'] ?? ''}',
      createdAt: _time(json['created_at']),
      closedAt: _time(json['closed_at']),
      events: events is List
          ? events
              .whereType<Map>()
              .map((e) => ItEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      canAct: json['can_act'] == true,
    );
  }
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class StockRequestList {
  const StockRequestList({
    required this.items,
    this.staff = false,
    this.myWarehouse,
    this.openNew = 0,
    this.openInProgress = 0,
    this.openReady = 0,
    this.balances = false,
  });

  final List<StockRequest> items;
  final bool staff;

  /// Можно ли смотреть остатки на складах — кнопка видна не всем.
  final bool balances;

  /// Склад кладовщика по его должности — его заявки в очереди наверху.
  final int? myWarehouse;
  final int openNew;
  final int openInProgress;
  final int openReady;

  factory StockRequestList.fromJson(Map<String, dynamic> json) {
    final open = json['open'];
    int count(String key) =>
        open is Map ? (open[key] as num?)?.toInt() ?? 0 : 0;
    return StockRequestList(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => StockRequest.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      staff: json['staff'] == true,
      myWarehouse: (json['my_warehouse'] as num?)?.toInt(),
      openNew: count('new'),
      openInProgress: count('in_progress'),
      openReady: count('ready'),
      balances: json['balances'] == true,
    );
  }
}

class StockResult {
  const StockResult({this.item, this.error, this.problem});

  final StockRequest? item;
  final String? error;
  final LoadProblem? problem;

  bool get ok => item != null;
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

Future<StockRequestList> fetchStockRequests({bool queue = false}) async {
  try {
    final response = await http
        .get(_uri('/api/stock-requests${queue ? '?scope=queue' : ''}'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    return StockRequestList.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

Future<StockRequest> fetchStockRequest(int id) async {
  try {
    final response = await http
        .get(_uri('/api/stock-requests/$id'), headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return StockRequest.fromJson(body['item'] as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

StockResult _result(http.Response response) {
  Map<String, dynamic> body = const {};
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) body = decoded;
  } catch (_) {}
  if ((response.statusCode == 200 || response.statusCode == 201) &&
      body['item'] is Map) {
    return StockResult(
        item: StockRequest.fromJson(Map<String, dynamic>.from(body['item'])));
  }
  final error = body['error'];
  return StockResult(
      error: error is String ? error : null,
      problem: problemForStatus(response.statusCode));
}

Future<StockResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const StockResult(problem: LoadProblem.denied);
    }
    return _result(response);
  } catch (e) {
    return StockResult(problem: problemOf(e));
  }
}

Future<StockResult> createStockRequest({
  required String purpose,
  required List<StockLine> lines,
  int? warehouse,
}) =>
    _post('/api/stock-requests', {
      'purpose': purpose,
      'warehouse': warehouse,
      'lines': [
        for (final l in lines)
          {'name': l.name, 'quantity': l.quantity, 'unit': l.unit},
      ],
    });

/// take, ready (с `missing`), issued, reject, cancel, comment.
Future<StockResult> stockRequestAction(int id, String action,
        {String comment = '', List<int>? missing}) =>
    _post('/api/stock-requests/$id', {
      'action': action,
      if (comment.isNotEmpty) 'comment': comment,
      if (missing != null) 'missing': missing,
    });
