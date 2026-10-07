import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/offline_cache.dart';
import '../utils/variables.dart';

/// Проходы за последний день, когда они есть.
class HomeAccess {
  final DateTime date;
  final String? firstIn;
  final String? lastOut;
  const HomeAccess({required this.date, this.firstIn, this.lastOut});
}

/// Сводка для главного экрана: по строке на раздел.
///
/// Сумм здесь нет и не будет: главный экран видит тот, кто стоит рядом.
class HomeSummary {
  final DateTime? today;
  final HomeAccess? access;

  /// Первое число месяца, за который есть последний листок.
  final DateTime? payslip;
  final int? leaveDays;
  final int menuCount;
  final List<String> dishes;

  const HomeSummary({
    this.today,
    this.access,
    this.payslip,
    this.leaveDays,
    this.menuCount = 0,
    this.dishes = const [],
  });

  static HomeSummary fromJson(Map<String, dynamic> body) {
    DateTime? day(Object? v) => v is String ? DateTime.tryParse(v) : null;

    final access = body['access'];
    final accessDate = access is Map ? day(access['date']) : null;
    final payslip = body['payslip'];
    final leave = body['leave'];
    final menu = body['menu'];
    return HomeSummary(
      today: day(body['today']),
      access: accessDate == null
          ? null
          : HomeAccess(
              date: accessDate,
              firstIn: (access as Map)['first_in'] as String?,
              lastOut: access['last_out'] as String?,
            ),
      payslip: payslip is Map &&
              payslip['year'] is num &&
              payslip['month'] is num
          ? DateTime((payslip['year'] as num).toInt(),
              (payslip['month'] as num).toInt())
          : null,
      leaveDays: leave is Map && leave['remaining_days'] is num
          ? (leave['remaining_days'] as num).toInt()
          : null,
      menuCount: menu is Map && menu['count'] is num
          ? (menu['count'] as num).toInt()
          : 0,
      dishes: menu is Map && menu['dishes'] is List
          ? [for (final d in menu['dishes'] as List) '$d']
          : const [],
    );
  }
}

const _cacheKey = 'home';

/// Сводка с сервера, а без связи — сохранённая в прошлый раз.
///
/// Меню из сохранённой сводки годится только на тот же день: вчерашний борщ
/// на главном экране хуже, чем никакого.
Future<HomeSummary?> fetchHomeSummary() async {
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/api/home'),
          headers: await authHeaders(),
          body: jsonEncode({}),
        )
        .timeout(const Duration(seconds: 15));
    if (await handledUnauthorized(response)) return null;
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> && body['message'] == 'Success') {
        await OfflineCache.save(_cacheKey, body);
        return HomeSummary.fromJson(body);
      }
    }
  } catch (_) {
    // Ниже — сохранённая.
  }
  return _cached();
}

Future<HomeSummary?> _cached() async {
  final saved = await OfflineCache.read(_cacheKey);
  if (saved == null) return null;
  final summary = HomeSummary.fromJson(saved);
  final now = DateTime.now();
  final today = summary.today;
  final sameDay = today != null &&
      today.year == now.year &&
      today.month == now.month &&
      today.day == now.day;
  if (sameDay) return summary;
  return HomeSummary(
    today: summary.today,
    access: summary.access,
    payslip: summary.payslip,
    leaveDays: summary.leaveDays,
  );
}
