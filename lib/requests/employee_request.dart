import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/variables.dart';


Future getEmployee(String iin, BuildContext context) async {

  SharedPreferences prefs = await SharedPreferences.getInstance();

  try {
    var response = await http.post(
      Uri.parse('${AppValues.baseUrl}/get_sname'),
      headers: {'Content-Type' : 'application/json'},
      body: jsonEncode({'emp_iin': iin}),
    );
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      if (jsonDecode(response.body)['message'] == 'Success' && iin!='') {
        prefs.setString('emp_iin', iin);
        return responseBody['employee'][0];
      }
    } else {
      print('Ошибка HTTP-запроса');
    }
  } catch (e) {
    print('Ошибка: $e');
  }
}
