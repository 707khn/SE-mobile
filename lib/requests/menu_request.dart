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

Future<Map<String, dynamic>> getMenuForDate(String date) async {
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
    return await _cachedMenu(date, problemForStatus(response.statusCode));
  } catch (e) {
    return await _cachedMenu(date, problemOf(e));
  }
}

/// Меню за этот день, полученное в прошлый раз. В столовой связь ловит хуже
/// всего, а меню нужно именно там.
Future<Map<String, dynamic>> _cachedMenu(
    String date, LoadProblem problem) async {
  final saved = await OfflineCache.read('menu_$date');
  if (saved != null) return saved;
  return {'message': 'Failure', 'items': [], problemKey: problem.name};
}
