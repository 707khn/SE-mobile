import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import '../utils/api.dart';

Future<List<List<String>>> getReportEntries(BuildContext context) async {
  final login = await SecureStorageHelper.instance.getEmployeeId();

  try {
    var response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/report'),
          headers: await authHeaders(),
          body: jsonEncode({'key_suffix': login}),
        )
        .timeout(const Duration(seconds: 15));
    if (await handledUnauthorized(response)) return <List<String>>[];
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      List<List<String>> report = [];
      if (responseBody['message'] == "Failure"){
        return report;
      } else {
        for (var entry in responseBody['report']) {
          report.add([
            entry['date'] as String,
            entry['time'] as String,
            entry['event'] as String,
            entry['door'] as String? ?? '',
          ]);
        }
        return report;
      }
    } else {
      return [["no"]];
    }
  } on TimeoutException {
    return [["no"]];
  } catch (e) {
    return [["no"]];
  }
}
