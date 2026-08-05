import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/variables.dart';
import '../utils/api.dart';

Future getEmployee(String iin, BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();

  try {
    var response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/get_sname'),
          headers: await authHeaders(),
          body: jsonEncode({'emp_iin': iin}),
        )
        .timeout(const Duration(seconds: 15));
    if (await handledUnauthorized(response)) return null;
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      if (responseBody['message'] == 'Success' && iin.isNotEmpty) {
        prefs.setString('emp_iin', iin);
        return responseBody['employee'][0];
      }
    }
  } on TimeoutException {
    return null;
  } catch (e) {
    return null;
  }
}
