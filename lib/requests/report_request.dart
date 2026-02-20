import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';

Future<List<List<String>>> getReportEntries(BuildContext context) async {
  final login = await SecureStorageHelper.instance.getLogin();

  try {
    var response = await http.post(
      Uri.parse('${AppValues.baseUrl}/report'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'key_suffix': login}),
    );
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      List<List<String>> report = [];
      if (responseBody['message'] == "Failure"){
        return report;
      } else {
        for (var entry in responseBody['report']) {
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
        return report;
      }
    } else {
      print('Ошибка HTTP-запроса');
      return [["no"]];
    }
  } catch (e) {
    print('Ошибка: $e');
    return [["no"]];
  }
}
