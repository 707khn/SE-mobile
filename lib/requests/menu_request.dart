import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/variables.dart';

/// Replaces the whole menu for [date]. The backend wipes that day's items and
/// re-inserts what is sent, so pass the complete list, not just the changes.
Future<bool> saveMenuForDate(String date, List<Map<String, dynamic>> items) async {
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/api/menu'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'date': date, 'items': items}),
        )
        .timeout(const Duration(seconds: 15));
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
          headers: {'Content-Type': 'application/json'},
        )
        .timeout(const Duration(seconds: 15));
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
