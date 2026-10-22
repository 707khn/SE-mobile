import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

double? _double(Object? raw) => (raw as num?)?.toDouble();

String lunchDay(DateTime day) => '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// Блюдо меню, которое можно заказать.
class LunchDish {
  const LunchDish(
      {required this.id,
      required this.category,
      required this.name,
      this.price,
      this.portion = ''});

  final int id;
  final String category;
  final String name;
  final double? price;
  final String portion;

  static LunchDish? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! num) return null;
    return LunchDish(
      id: (raw['id'] as num).toInt(),
      category: '${raw['category'] ?? ''}',
      name: '${raw['name'] ?? ''}',
      price: _double(raw['price']),
      portion: '${raw['portion'] ?? ''}',
    );
  }
}

class LunchLine {
  const LunchLine(
      {required this.category,
      required this.name,
      this.price,
      this.quantity = 1});

  final String category;
  final String name;
  final double? price;
  final int quantity;

  static LunchLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return LunchLine(
      category: '${raw['category'] ?? ''}',
      name: '${raw['name'] ?? ''}',
      price: _double(raw['price']),
      quantity: (raw['quantity'] as num?)?.toInt() ?? 1,
    );
  }
}

class LunchOrder {
  const LunchOrder({
    required this.id,
    this.lines = const [],
    this.note = '',
    this.total = 0,
    this.served = false,
    this.employeeName = '',
    this.employeeDepartment = '',
  });

  final int id;
  final List<LunchLine> lines;
  final String note;
  final double total;
  final bool served;
  final String employeeName;
  final String employeeDepartment;

  static LunchOrder? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final employee = raw['employee'];
    return LunchOrder(
      id: (raw['id'] as num?)?.toInt() ?? 0,
      lines: ((raw['lines'] as List?) ?? const [])
          .map(LunchLine.fromJson)
          .whereType<LunchLine>()
          .toList(),
      note: '${raw['note'] ?? ''}',
      total: _double(raw['total']) ?? 0,
      served: raw['served'] == true,
      employeeName: employee is Map ? '${employee['name'] ?? ''}' : '',
      employeeDepartment:
          employee is Map ? '${employee['department'] ?? ''}' : '',
    );
  }
}

class LunchDay {
  const LunchDay({
    this.open = false,
    this.cutoff = '',
    this.canteen = false,
    this.menu = const [],
    this.order,
  });

  /// Можно ли ещё заказать или поправить заказ.
  final bool open;
  final String cutoff;
  final bool canteen;
  final List<LunchDish> menu;
  final LunchOrder? order;

  factory LunchDay.fromJson(Map<String, dynamic> json) => LunchDay(
        open: json['open'] == true,
        cutoff: '${json['cutoff'] ?? ''}',
        canteen: json['canteen'] == true,
        menu: ((json['menu'] as List?) ?? const [])
            .map(LunchDish.fromJson)
            .whereType<LunchDish>()
            .toList(),
        order: LunchOrder.fromJson(json['order']),
      );
}

class LunchDishCount {
  const LunchDishCount(
      {required this.category, required this.name, required this.quantity});

  final String category;
  final String name;
  final int quantity;
}

class LunchSummary {
  const LunchSummary(
      {this.count = 0,
      this.served = 0,
      this.dishes = const [],
      this.orders = const []});

  final int count;
  final int served;
  final List<LunchDishCount> dishes;
  final List<LunchOrder> orders;

  factory LunchSummary.fromJson(Map<String, dynamic> json) => LunchSummary(
        count: (json['count'] as num?)?.toInt() ?? 0,
        served: (json['served'] as num?)?.toInt() ?? 0,
        dishes: ((json['dishes'] as List?) ?? const [])
            .whereType<Map>()
            .map((d) => LunchDishCount(
                category: '${d['category'] ?? ''}',
                name: '${d['name'] ?? ''}',
                quantity: (d['quantity'] as num?)?.toInt() ?? 0))
            .toList(),
        orders: ((json['orders'] as List?) ?? const [])
            .map(LunchOrder.fromJson)
            .whereType<LunchOrder>()
            .toList(),
      );
}

class LunchResult {
  const LunchResult({this.order, this.ok = false, this.error, this.problem});

  final LunchOrder? order;
  final bool ok;
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

Future<LunchDay> fetchLunchDay(DateTime day) async =>
    LunchDay.fromJson(await _get('/api/lunch-orders?date=${lunchDay(day)}'));

Future<LunchSummary> fetchLunchSummary(DateTime day) async =>
    LunchSummary.fromJson(
        await _get('/api/lunch-orders/summary?date=${lunchDay(day)}'));

Future<LunchResult> _send(
    Future<http.Response> Function(Map<String, String>) call) async {
  try {
    final response =
        await call(await authHeaders()).timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const LunchResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if (response.statusCode == 200 || response.statusCode == 201) {
      return LunchResult(ok: true, order: LunchOrder.fromJson(parsed['order']));
    }
    final error = parsed['error'];
    return LunchResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return LunchResult(problem: problemOf(e));
  }
}

/// Заказ на день целиком: {id блюда: количество}.
Future<LunchResult> saveLunchOrder(DateTime day, Map<int, int> items,
        {String note = ''}) =>
    _send((headers) => http.put(_uri('/api/lunch-orders'),
        headers: headers,
        body: jsonEncode({
          'date': lunchDay(day),
          'items': [
            for (final e in items.entries)
              {'menu_item_id': e.key, 'quantity': e.value}
          ],
          if (note.isNotEmpty) 'note': note,
        })));

Future<LunchResult> cancelLunchOrder(DateTime day) => _send((headers) => http
    .delete(_uri('/api/lunch-orders?date=${lunchDay(day)}'), headers: headers));

Future<LunchResult> markLunchServed(int id, bool served) =>
    _send((headers) => http.post(_uri('/api/lunch-orders/$id/served'),
        headers: headers, body: jsonEncode({'served': served})));
