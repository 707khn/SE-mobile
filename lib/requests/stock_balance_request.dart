import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

/// Сколько позиции лежит на одном складе.
class StockPlace {
  const StockPlace({required this.warehouse, required this.quantity});

  final String warehouse;
  final double quantity;
}

/// Позиция номенклатуры со всеми складами, где она есть.
class StockBalance {
  const StockBalance({
    required this.name,
    this.code = '',
    this.unit = '',
    this.total = 0,
    this.places = const [],
  });

  final String name;
  final String code;
  final String unit;
  final double total;
  final List<StockPlace> places;

  static StockBalance? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.isEmpty) return null;
    return StockBalance(
      name: name,
      code: raw['code'] as String? ?? '',
      unit: raw['unit'] as String? ?? '',
      total: (raw['total'] as num?)?.toDouble() ?? 0,
      places: ((raw['warehouses'] as List?) ?? const [])
          .whereType<Map>()
          .map((w) => StockPlace(
              warehouse: w['name'] as String? ?? '',
              quantity: (w['quantity'] as num?)?.toDouble() ?? 0))
          .toList(),
    );
  }
}

class StockBalanceSearch {
  const StockBalanceSearch({
    this.items = const [],
    this.asOf,
    this.stale = false,
    this.more = false,
    this.warehouses = const [],
  });

  final List<StockBalance> items;

  /// Когда остатки загружали последний раз; null — не загружали ни разу.
  final DateTime? asOf;

  /// Какой-то склад не обновлялся больше трёх дней.
  final bool stale;

  /// Нашлось больше, чем показано, — стоит уточнить запрос.
  final bool more;
  final List<String> warehouses;

  factory StockBalanceSearch.fromJson(Map<String, dynamic> json) {
    final asOf = json['as_of'];
    return StockBalanceSearch(
      items: ((json['items'] as List?) ?? const [])
          .map(StockBalance.fromJson)
          .whereType<StockBalance>()
          .toList(),
      asOf: asOf is String ? DateTime.tryParse(asOf)?.toLocal() : null,
      stale: json['stale'] == true,
      more: json['more'] == true,
      warehouses: ((json['warehouses'] as List?) ?? const [])
          .whereType<Map>()
          .map((w) => w['name'])
          .whereType<String>()
          .toList(),
    );
  }
}

/// 5.0 → «5», 2.5 → «2,5».
String stockQuantity(double value) {
  final text = value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
  return text.replaceAll('.', ',');
}

Future<StockBalanceSearch> searchStockBalances(String query) async {
  try {
    final uri = Uri.parse('${AppValues.baseUrl}/api/stock-balances')
        .replace(queryParameters: query.isEmpty ? null : {'q': query});
    final response = await http
        .get(uri, headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    return StockBalanceSearch.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}
