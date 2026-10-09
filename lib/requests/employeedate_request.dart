import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import '../utils/variables.dart';
import '../utils/access_report.dart';
import '../utils/api.dart';
import '../utils/load_problem.dart';

/// Проходы сотрудника [name] за дни с [startdate] по [enddate].
///
/// Имя передаётся явно. Прежде оно бралось из настроек — «последний
/// выбранный», — и выгрузка отдела не могла запросить остальных.
Future<AccessReport> getEmployeeDate(
    BuildContext context, startdate, enddate, {required String name}) async {
  try {
    var response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/director_report'),
          headers: await authHeaders(),
          body: jsonEncode({'emp_sname': name, 'start_date': startdate, 'end_date': enddate}),
        )
        .timeout(const Duration(seconds: 15));
    if (await handledUnauthorized(response)) return AccessReport.empty;
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      final coverage = AccessCoverage.fromJson(responseBody['coverage']);
      List<List<String>> report = [];
      if (responseBody['message'] == "Failure") {
        return AccessReport(report, coverage);
      } else {
        for (var entry in responseBody['director_report']) {
          List<String> stringEntry = [];
          entry.forEach((key, value) {
            if (value is DateTime) {
              stringEntry.add(value.toString());
            } else if (value is String) {
              stringEntry.add(value);
            } else {
              stringEntry.add(value.toString());
            }
          });
          report.add(stringEntry);
        }
        return AccessReport(report, coverage);
      }

    } else {
      return AccessReport.failedWith(problemForStatus(response.statusCode));
    }
  } catch (e) {
    return AccessReport.failedWith(problemOf(e));
  }
}