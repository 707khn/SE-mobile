import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/variables.dart';
import '../utils/api.dart';

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
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    return {'message': 'Failure', 'entries': []};
  } on TimeoutException {
    return {'message': 'Failure', 'entries': []};
  } catch (_) {
    return {'message': 'Failure', 'entries': []};
  }
}
