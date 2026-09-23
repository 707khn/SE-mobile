import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import '../utils/access_report.dart';
import '../utils/api.dart';

/// [employeeId] overrides the signed-in user — used by the admin panel.
Future<AccessReport> getReportDateEntries(BuildContext context, startdate, enddate,
    {String? employeeId}) async {
  final login = (employeeId != null && employeeId.isNotEmpty)
      ? employeeId
      : await SecureStorageHelper.instance.getEmployeeId();

  try {
    var response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/reportdate'),
          headers: await authHeaders(),
          body: jsonEncode({'key_suffix': login, 'start_date': startdate, 'end_date': enddate}),
        )
        .timeout(const Duration(seconds: 15));
    if (await handledUnauthorized(response)) return AccessReport.empty;
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      final coverage = AccessCoverage.fromJson(responseBody['coverage']);
      List<List<String>> report = [];
      if (responseBody['message'] == "Failure") {
        return AccessReport(report, coverage);
      }
      for (var entry in responseBody['report']) {
        report.add([
          entry['date'] as String,
          entry['time'] as String,
          entry['event'] as String,
          entry['door'] as String? ?? '',
        ]);
      }
      return AccessReport(report, coverage);
    } else {
      return AccessReport.failed;
    }
  } on TimeoutException {
    return AccessReport.failed;
  } catch (e) {
    return AccessReport.failed;
  }
}