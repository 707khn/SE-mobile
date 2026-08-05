import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import '../utils/api.dart';

Future<List<String>> getAllEmployees(BuildContext context) async {
  final keySuffix = await SecureStorageHelper.instance.getEmployeeId();

  try {
    var response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/get_sname'),
          headers: await authHeaders(),
          body: jsonEncode({'key_suffix': keySuffix}),
        )
        .timeout(const Duration(seconds: 15));
    if (await handledUnauthorized(response)) return ["no"];
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      List<String> employeeNames = List<String>.from(responseBody['fio']);
      return employeeNames;
    } else {
      return ["no"];
    }
  } on TimeoutException {
    return ["no"];
  } catch (e) {
    return ["no"];
  }
}
