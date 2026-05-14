import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';

class LeaveBalance {
  final String type;
  final int totalDays;
  final int usedDays;
  final int remainingDays;

  LeaveBalance({
    required this.type,
    required this.totalDays,
    required this.usedDays,
    required this.remainingDays,
  });
}

class LeaveRecord {
  final String type;
  final String startDate;
  final String endDate;
  final int days;
  final String status;

  LeaveRecord({
    required this.type,
    required this.startDate,
    required this.endDate,
    required this.days,
    required this.status,
  });
}

class LeaveData {
  final String employee;
  final List<LeaveBalance> balances;
  final List<LeaveRecord> history;

  LeaveData({
    required this.employee,
    required this.balances,
    required this.history,
  });
}

Future<LeaveData?> getLeaves(BuildContext context) async {
  final login = await SecureStorageHelper.instance.getEmployeeId();

  try {
    var response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/leaves'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'key_suffix': login}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      if (responseBody['message'] == 'Failure') {
        return null;
      }
      var data = responseBody['leaves'];
      return LeaveData(
        employee: data['employee'],
        balances: (data['balances'] as List)
            .map((b) => LeaveBalance(
                  type: b['type'],
                  totalDays: b['total_days'],
                  usedDays: b['used_days'],
                  remainingDays: b['remaining_days'],
                ))
            .toList(),
        history: (data['history'] as List)
            .map((h) => LeaveRecord(
                  type: h['type'],
                  startDate: h['start_date'],
                  endDate: h['end_date'],
                  days: h['days'],
                  status: h['status'],
                ))
            .toList(),
      );
    } else {
      return null;
    }
  } on TimeoutException {
    return null;
  } catch (e) {
    return null;
  }
}
