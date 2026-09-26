import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

Future<Map<String, dynamic>> getAttendanceForDate(String date) async {
  try {
    final response = await http
        .get(
          Uri.parse('${AppValues.baseUrl}/api/attendance?date=$date'),
          headers: await authHeaders(),
        )
        .timeout(const Duration(seconds: 15));
    if (await handledUnauthorized(response)) {
      return {'message': 'Failure', 'events': []};
    }
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    return _failure(problemForStatus(response.statusCode));
  } catch (e) {
    return _failure(problemOf(e));
  }
}

Map<String, dynamic> _failure(LoadProblem problem) =>
    {'message': 'Failure', 'events': [], problemKey: problem.name};
