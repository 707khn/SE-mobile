import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/variables.dart';
import '../utils/api.dart';

/// Лента для сотрудника: новости сайта и одобренные объявления.
Future<Map<String, dynamic>> getNews() async {
  try {
    final response = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/news'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return {'message': 'Failure', 'items': []};
    }
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    return {'message': 'Failure', 'items': []};
  } on TimeoutException {
    return {'message': 'Failure', 'items': []};
  } catch (_) {
    return {'message': 'Failure', 'items': []};
  }
}

/// Всё вместе с неодобренным — для администратора.
Future<Map<String, dynamic>> getNewsQueue() async {
  try {
    final response = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/admin/news'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return {'message': 'Failure', 'items': [], 'pending': 0};
    }
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    return {'message': 'Failure', 'items': [], 'pending': 0};
  } catch (_) {
    return {'message': 'Failure', 'items': [], 'pending': 0};
  }
}

/// Объявление, набранное администратором. Публикуется сразу.
Future<bool> createAnnouncement(String title, String summary) async {
  try {
    final response = await http
        .post(Uri.parse('${AppValues.baseUrl}/api/admin/news'),
            headers: await authHeaders(),
            body: jsonEncode({'title': title, 'summary': summary}))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) return false;
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// Одобрить объявление из очереди или снять его с публикации.
Future<bool> setNewsPublished(int id, bool published) async {
  try {
    final response = await http
        .post(Uri.parse('${AppValues.baseUrl}/api/admin/news/$id'),
            headers: await authHeaders(),
            body: jsonEncode({'is_published': published}))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) return false;
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

Future<bool> deleteNews(int id) async {
  try {
    final response = await http
        .delete(Uri.parse('${AppValues.baseUrl}/api/admin/news/$id'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) return false;
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}
