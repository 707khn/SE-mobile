import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import '../utils/access_cache.dart';
import '../utils/access_report.dart';
import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/offline_cache.dart';

/// [employeeId] overrides the signed-in user — used by the admin panel.
Future<AccessReport> getReportDateEntries(BuildContext context, startdate, enddate,
    {String? employeeId}) async {
  final login = (employeeId != null && employeeId.isNotEmpty)
      ? employeeId
      : await SecureStorageHelper.instance.getEmployeeId();
  // Копию держим только своих проходов: чужие (администратор смотрит
  // сотрудника) на телефоне оставлять незачем.
  final ownKey = (employeeId == null || employeeId.isEmpty) &&
          login != null &&
          login.isNotEmpty
      ? AccessCache.key(login)
      : null;

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
      if (ownKey != null) {
        await OfflineCache.save(
            ownKey,
            AccessCache.merge(await OfflineCache.read(ownKey), responseBody,
                '$startdate', '$enddate'));
      }
      return AccessReport(report, coverage);
    } else {
      return await _savedOr(ownKey, '$startdate', '$enddate',
          problemForStatus(response.statusCode));
    }
  } catch (e) {
    return _savedOr(ownKey, '$startdate', '$enddate', problemOf(e));
  }
}

/// Без связи — проходы за период из копии, если этот период в ней есть.
Future<AccessReport> _savedOr(
    String? key, String from, String to, LoadProblem problem) async {
  if (key != null) {
    final saved = AccessCache.answer(await OfflineCache.read(key),
        from: from, to: to);
    if (saved != null) return saved;
  }
  return AccessReport.failedWith(problem);
}