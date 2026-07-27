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

Future<String?> _resolveEmployeeId() async {
  var id = await SecureStorageHelper.instance.getEmployeeId();
  if (id != null && id.isNotEmpty) return id;
  final iin = await SecureStorageHelper.instance.getLogin();
  if (iin == null || iin.isEmpty) return null;
  try {
    final r = await http.post(
      Uri.parse('${AppValues.baseUrl}/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'iin': iin}),
    ).timeout(const Duration(seconds: 10));
    if (r.statusCode == 200) {
      final b = jsonDecode(r.body) as Map<String, dynamic>;
      if (b['message'] == 'Success') {
        final fresh = (b['employee_id'] as String?) ?? '';
        if (fresh.isNotEmpty) {
          await SecureStorageHelper.instance.saveEmployeeId(fresh);
          return fresh;
        }
      }
    }
  } catch (_) {}
  return null;
}

/// [employeeId] overrides the signed-in user — used by the admin panel.
Future<LeaveData?> getLeaves(BuildContext context, {String? employeeId}) async {
  final login = (employeeId != null && employeeId.isNotEmpty)
      ? employeeId
      : await _resolveEmployeeId();
  if (login == null || login.isEmpty) return null;

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
