import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/variables.dart';

Future<Map<String, dynamic>> getAttendanceForDate(String date) async {
  try {
    final response = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/attendance?date=$date'))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    return {'message': 'Failure', 'events': []};
  } on TimeoutException {
    return {'message': 'Failure', 'events': []};
  } catch (_) {
    return {'message': 'Failure', 'events': []};
  }
}
