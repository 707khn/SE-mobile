import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

Future<List<List<String>>> getEmployeeDate(BuildContext context, startdate, enddate) async {
  final prefs = await SharedPreferences.getInstance();
  final emp_sname = prefs.getString('emp_sname');

  try {
    var response = await http.post(
      Uri.parse('http://cp.se-btrz.com/director_report'),
      headers: {'Content-Type' : 'application/json'},
      body: jsonEncode({'emp_sname': emp_sname, 'start_date': startdate, 'end_date': enddate}),
    );
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      List<List<String>> report = [];
      if (responseBody['message'] == "Failure"){
        return report;
      } else {
        for (var entry in responseBody['director_report']) {
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