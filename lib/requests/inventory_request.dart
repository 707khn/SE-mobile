import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'assignment_request.dart' show AssignPerson;

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

AssignPerson? _person(Object? raw) =>
    raw is Map ? AssignPerson.fromJson(Map<String, dynamic>.from(raw)) : null;

double? _number(Object? raw) => (raw as num?)?.toDouble();

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) =>
    ((raw as List?) ?? const [])
        .whereType<Map>()
        .map((e) => parse(Map<String, dynamic>.from(e)))
        .toList();

/// Склад из последней выгрузки остатков 1С.
class InventoryWarehouse {
  const InventoryWarehouse({required this.name, this.items = 0, this.asOf});

  final String name;
  final int items;
  final DateTime? asOf;

  factory InventoryWarehouse.fromJson(Map<String, dynamic> json) =>
      InventoryWarehouse(
        name: '${json['name'] ?? ''}',
        items: (json['items'] as num?)?.toInt() ?? 0,
        asOf: _time(json['as_of']),
      );
}

/// Пересчёт склада: open — идёт, closed — подведён итог.
class InventoryCount {
  const InventoryCount({
    required this.id,
    this.warehouse = '',
    this.status = 'open',
    this.asOf,
    this.startedAt,
    this.startedBy,
    this.closedAt,
    this.lines = 0,
    this.counted = 0,
    this.differences = 0,
  });

  final int id;
  final String warehouse;
  final String status;
  final DateTime? asOf;
  final DateTime? startedAt;
  final AssignPerson? startedBy;
  final DateTime? closedAt;
  final int lines;
  final int counted;
  final int differences;

  bool get open => status == 'open';

  factory InventoryCount.fromJson(Map<String, dynamic> json) => InventoryCount(
        id: (json['id'] as num?)?.toInt() ?? 0,
        warehouse: '${json['warehouse'] ?? ''}',
        status: '${json['status'] ?? 'open'}',
        asOf: _time(json['as_of']),
        startedAt: _time(json['started_at']),
        startedBy: _person(json['started_by']),
        closedAt: _time(json['closed_at']),
        lines: (json['lines'] as num?)?.toInt() ?? 0,
        counted: (json['counted'] as num?)?.toInt() ?? 0,
        differences: (json['differences'] as num?)?.toInt() ?? 0,
      );
}

/// Позиция пересчёта. [diff] — факт минус 1С; null — ещё не посчитана.
class InventoryLine {
  const InventoryLine({
    required this.id,
    required this.name,
    this.code = '',
    this.unit = '',
    this.expected = 0,
    this.counted,
    this.extra = false,
    this.diff,
  });

  final int id;
  final String name;
  final String code;
  final String unit;
  final double expected;
  final double? counted;
  final bool extra;
  final double? diff;

  factory InventoryLine.fromJson(Map<String, dynamic> json) => InventoryLine(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: '${json['name'] ?? ''}',
        code: '${json['code'] ?? ''}',
        unit: '${json['unit'] ?? ''}',
        expected: _number(json['expected']) ?? 0,
        counted: _number(json['counted']),
        extra: json['extra'] == true,
        diff: _number(json['diff']),
      );
}

class InventoryDesk {
  const InventoryDesk({this.warehouses = const [], this.counts = const []});

  final List<InventoryWarehouse> warehouses;
  final List<InventoryCount> counts;

  factory InventoryDesk.fromJson(Map<String, dynamic> json) => InventoryDesk(
        warehouses: _list(json['warehouses'], InventoryWarehouse.fromJson),
        counts: _list(json['counts'], InventoryCount.fromJson),
      );
}

class InventorySheet {
  const InventorySheet({required this.count, this.lines = const []});

  final InventoryCount count;
  final List<InventoryLine> lines;

  factory InventorySheet.fromJson(Map<String, dynamic> json) => InventorySheet(
        count: InventoryCount.fromJson(
            Map<String, dynamic>.from(json['count'] as Map? ?? const {})),
        lines: _list(json['lines'], InventoryLine.fromJson),
      );
}

class InventoryResult {
  const InventoryResult(
      {this.ok = false, this.line, this.countId, this.error, this.problem});

  final bool ok;
  final InventoryLine? line;

  /// Начатый пересчёт — или уже идущий на этом складе (error: exists).
  final int? countId;
  final String? error;
  final LoadProblem? problem;
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

Future<InventoryDesk> fetchInventory() async =>
    InventoryDesk.fromJson(await _get('/api/inventory'));

Future<InventorySheet> fetchInventoryCount(int id) async =>
    InventorySheet.fromJson(await _get('/api/inventory/$id'));

Future<InventoryResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const InventoryResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    final line = parsed['line'];
    final count = parsed['count'];
    final countId = count is Map
        ? (count['id'] as num?)?.toInt()
        : (parsed['id'] as num?)?.toInt();
    if (response.statusCode == 200 || response.statusCode == 201) {
      return InventoryResult(
          ok: true,
          countId: countId,
          line: line is Map
              ? InventoryLine.fromJson(Map<String, dynamic>.from(line))
              : null);
    }
    final error = parsed['error'];
    return InventoryResult(
        countId: countId,
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return InventoryResult(problem: problemOf(e));
  }
}

Future<InventoryResult> startInventory(String warehouse) =>
    _post('/api/inventory', {'warehouse': warehouse});

/// Найти позицию по коду ([quantity] null) или посчитать её.
///
/// [lineId] вместе с [barcode] — запомнить, что этот штрихкод — она.
Future<InventoryResult> scanInventory(int countId,
        {String? barcode, int? lineId, String? quantity, bool set = false}) =>
    _post('/api/inventory/$countId/scan', {
      if (barcode != null && barcode.isNotEmpty) 'barcode': barcode,
      if (lineId != null) 'line_id': lineId,
      if (quantity != null) 'quantity': quantity,
      if (set) 'mode': 'set',
    });

/// Нашлось на складе то, чего нет в 1С.
Future<InventoryResult> addInventoryExtra(
        int countId, Map<String, String> fields,
        {String? barcode}) =>
    _post('/api/inventory/$countId/extra', {
      ...fields,
      if (barcode != null && barcode.isNotEmpty) 'barcode': barcode,
    });

/// close — подвести итог; remove — убрать начатый по ошибке.
Future<InventoryResult> inventoryAction(int countId, String action) =>
    _post('/api/inventory/$countId', {'action': action});
