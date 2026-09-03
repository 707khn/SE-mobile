import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/variables.dart';
import '../utils/api.dart';
import '../utils/offline_cache.dart';

/// Телефонный справочник предприятия целиком.
///
/// Приходит одним куском — записей чуть больше сотни, — а поиск и разбивку
/// по отделам делает экран: так справочник листается без обращений к серверу.
Future<Map<String, dynamic>> getDirectory() async {
  try {
    final response = await http
        .get(
          Uri.parse('${AppValues.baseUrl}/api/directory'),
          headers: await authHeaders(),
        )
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return {'message': 'Failure', 'entries': []};
    }
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      await OfflineCache.save('directory', body);
      return body;
    }
    return await _cachedDirectory();
  } on TimeoutException {
    return await _cachedDirectory();
  } catch (_) {
    return await _cachedDirectory();
  }
}

/// Справочник, полученный в прошлый раз: внутренний номер нужен как раз
/// там, где связи нет.
Future<Map<String, dynamic>> _cachedDirectory() async {
  final saved = await OfflineCache.read('directory');
  if (saved != null) return saved;
  return {'message': 'Failure', 'entries': []};
}
