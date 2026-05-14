import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/variables.dart';

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
