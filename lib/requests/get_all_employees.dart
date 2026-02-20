import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';

Future<List<String>> getAllEmployees(BuildContext context) async {
  final keySuffix = await SecureStorageHelper.instance.getLogin();

  try {
    var response = await http.post(
      Uri.parse('${AppValues.baseUrl}/get_sname'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'key_suffix': keySuffix}),
    );
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      List<String> employeeNames = List<String>.from(responseBody['fio']);
      return employeeNames;
    } else {
      print('Ошибка HTTP-запроса');
      return ["no"];
    }
  } catch (e) {
    print('Ошибка: $e');
    return ["no"];
  }
}
