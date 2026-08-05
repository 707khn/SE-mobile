import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/variables.dart';
import '../utils/api.dart';

/// One row of the staff directory shown in the admin panel.
class AdminEmployee {
  const AdminEmployee({
    required this.employeeId,
    required this.fullName,
    required this.jobTitle,
    required this.department,
    required this.iin,
    required this.login,
    required this.payslipCount,
    required this.accessCount,
    required this.leaveCount,
  });

  final String employeeId;
  final String fullName;
  final String jobTitle;
  final String department;
  final String iin;

  /// Empty when the person has no way to sign in to the app.
  final String login;

  final int payslipCount;
  final int accessCount;
  final int leaveCount;

  bool get hasLogin => login.isNotEmpty;

  factory AdminEmployee.fromJson(Map<String, dynamic> json) => AdminEmployee(
        employeeId: (json['employee_id'] as String?) ?? '',
        fullName: (json['full_name'] as String?) ?? '',
        jobTitle: (json['job_title'] as String?) ?? '',
        department: (json['department'] as String?) ?? '',
        iin: (json['iin'] as String?) ?? '',
        login: (json['login'] as String?) ?? '',
        payslipCount: (json['payslip_count'] as num?)?.toInt() ?? 0,
        accessCount: (json['access_count'] as num?)?.toInt() ?? 0,
        leaveCount: (json['leave_count'] as num?)?.toInt() ?? 0,
      );
}

/// Returns every employee on record. Throws on failure so the screen can tell
/// an empty company apart from an unreachable server.
Future<List<AdminEmployee>> fetchAllEmployees() async {
  final response = await http
      .get(
        Uri.parse('${AppValues.baseUrl}/api/admin/employees'),
        headers: await authHeaders(),
      )
      .timeout(const Duration(seconds: 30));

  if (await handledUnauthorized(response)) return const <AdminEmployee>[];
  if (response.statusCode != 200) {
    throw HttpException('HTTP ${response.statusCode}');
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  final rows = (body['employees'] as List<dynamic>?) ?? [];
  return rows
      .map((e) => AdminEmployee.fromJson(e as Map<String, dynamic>))
      .toList();
}

class HttpException implements Exception {
  const HttpException(this.message);
  final String message;
  @override
  String toString() => 'HttpException: $message';
}
