import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/month_summary.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';

/// Итоги месяца по проходам. [employeeId] — чужие, для администратора.
///
/// Не загрузилось — бросает [LoadFailure] с причиной. null — сервер итогов
/// ещё не умеет (обновили приложение раньше сервера): тогда карточки нет.
Future<MonthSummary?> getMonthSummary(DateTime month,
    {String? employeeId}) async {
  final login = (employeeId != null && employeeId.isNotEmpty)
      ? employeeId
      : await SecureStorageHelper.instance.getEmployeeId();
  final http.Response response;
  try {
    response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/report/month'),
          headers: await authHeaders(),
          body: jsonEncode({'key_suffix': login, 'month': monthKey(month)}),
        )
        .timeout(const Duration(seconds: 15));
  } catch (e) {
    throw LoadFailure(problemOf(e), '$e');
  }
  if (await handledUnauthorized(response)) {
    throw const LoadFailure(LoadProblem.denied);
  }
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) {
    throw LoadFailure(problemForStatus(response.statusCode),
        'HTTP ${response.statusCode}');
  }
  final summary = MonthSummary.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>);
  if (summary == null) {
    throw const LoadFailure(LoadProblem.server, 'bad month summary');
  }
  return summary;
}
