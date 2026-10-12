import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/variables.dart';
import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/offline_cache.dart';

/// Replaces the whole menu for [date]. The backend wipes that day's items and
/// re-inserts what is sent, so pass the complete list, not just the changes.
Future<bool> saveMenuForDate(String date, List<Map<String, dynamic>> items) async {
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/api/menu'),
          headers: await authHeaders(),
          body: jsonEncode({'date': date, 'items': items}),
        )
        .timeout(const Duration(seconds: 15));
    if (await handledUnauthorized(response)) return false;
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body['message'] == 'Success';
    }
    return false;
  } on TimeoutException {
    return false;
  } catch (_) {
    return false;
  }
}

/// Меню за [date].
///
/// Не загрузилось — отдаёт меню, сохранённое в прошлый раз, если [offline].
/// Редактору меню копия не годится: он сохраняет день целиком, и правка
/// старой копии затёрла бы на сервере всё, что поменяли после неё, а пустой
/// день вместо неполученного — всё меню этого дня.
Future<Map<String, dynamic>> getMenuForDate(String date,
    {bool offline = true}) async {
  try {
    final response = await http
        .get(
          Uri.parse('${AppValues.baseUrl}/api/menu?date=$date'),
          headers: await authHeaders(),
        )
        .timeout(const Duration(seconds: 15));
    if (await handledUnauthorized(response)) {
      return {'message': 'Failure', 'items': []};
    }
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      await OfflineCache.save('menu_$date', body);
      // Две недели вокруг сегодняшнего — с запасом на меню, выложенное
      // вперёд; старее никто не открывает.
      await OfflineCache.trim('menu_', keep: 14);
      return body;
    }
    return await _cachedMenu(date, problemForStatus(response.statusCode),
        offline: offline);
  } catch (e) {
    return await _cachedMenu(date, problemOf(e), offline: offline);
  }
}

/// Меню за этот день, полученное в прошлый раз. В столовой связь ловит хуже
/// всего, а меню нужно именно там.
Future<Map<String, dynamic>> _cachedMenu(String date, LoadProblem problem,
    {required bool offline}) async {
  final saved = offline ? await OfflineCache.read('menu_$date') : null;
  if (saved != null) return saved;
  return {'message': 'Failure', 'items': [], problemKey: problem.name};
}
