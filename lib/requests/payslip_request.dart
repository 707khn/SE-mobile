import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';

class PayslipItem {
  final String name;
  final double amount;

  PayslipItem({required this.name, required this.amount});
}

class PayslipData {
  final String period;
  final String employee;
  final List<PayslipItem> accruals;
  final List<PayslipItem> deductions;
  final double totalAccruals;
  final double totalDeductions;
  final double netPay;

  PayslipData({
    required this.period,
    required this.employee,
    required this.accruals,
    required this.deductions,
    required this.totalAccruals,
    required this.totalDeductions,
    required this.netPay,
  });
}

Future<PayslipData?> getPayslip(BuildContext context, String month, String year) async {
  final login = await SecureStorageHelper.instance.getLogin();

  try {
    var response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/payslip'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'key_suffix': login, 'month': month, 'year': year}),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      if (responseBody['message'] == 'Failure') {
        return null;
      }
      var p = responseBody['payslip'];
      return PayslipData(
        period: p['period'],
        employee: p['employee'],
        accruals: (p['accruals'] as List)
            .map((e) => PayslipItem(name: e['name'], amount: (e['amount'] as num).toDouble()))
            .toList(),
        deductions: (p['deductions'] as List)
            .map((e) => PayslipItem(name: e['name'], amount: (e['amount'] as num).toDouble()))
            .toList(),
        totalAccruals: (p['total_accruals'] as num).toDouble(),
        totalDeductions: (p['total_deductions'] as num).toDouble(),
        netPay: (p['net_pay'] as num).toDouble(),
      );
    } else {
      print('Ошибка HTTP-запроса: ${response.statusCode}');
      return null;
    }
  } on TimeoutException {
    print('Превышено время ожидания запроса');
    return null;
  } catch (e) {
    print('Ошибка: $e');
    return null;
  }
}
