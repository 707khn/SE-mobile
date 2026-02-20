import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

Future<List<String>> getAllEmployees(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  final keySuffix = prefs.getString('login');

  try {
    var response = await http.post(
      Uri.parse('http://cp.se-btrz.com/get_sname'),
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
