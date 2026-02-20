import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

Future<List<List<String>>> getReportDateEntries(BuildContext context, startdate, enddate) async {
  final prefs = await SharedPreferences.getInstance();
  final login = prefs.getString('login');

  try {
    var response = await http.post(
      Uri.parse('http://cp.se-btrz.com/reportdate'),
      headers: {'Content-Type' : 'application/json'},
      body: jsonEncode({'key_suffix': login, 'start_date': startdate, 'end_date': enddate}),
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