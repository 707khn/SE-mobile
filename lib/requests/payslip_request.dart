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

class PayslipPaidItem {
  final String paymentType;
  final String period;
  final String document;
  final String date;
  final double amount;

  PayslipPaidItem({
    required this.paymentType,
    required this.period,
    required this.document,
    required this.date,
    required this.amount,
  });
}

class PayslipData {
  final String period;
  final String employee;
  final String position;
  final String department;
  final List<PayslipItem> accruals;
  final List<PayslipItem> deductions;
  final List<PayslipPaidItem> paid;
  final List<PayslipItem> benefits;
  final List<PayslipItem> reference;
  final double totalAccruals;
  final double totalDeductions;
  final double totalPaid;
  final double netPay;
  final double debtStart;
  final double debtEnd;

  PayslipData({
    required this.period,
    required this.employee,
    this.position = '',
    this.department = '',
    required this.accruals,
    required this.deductions,
    this.paid = const [],
    this.benefits = const [],
    this.reference = const [],
    required this.totalAccruals,
    required this.totalDeductions,
    this.totalPaid = 0.0,
    required this.netPay,
    this.debtStart = 0.0,
    this.debtEnd = 0.0,
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
        position: p['position'] ?? '',
        department: p['department'] ?? '',
        accruals: (p['accruals'] as List)
            .map((e) => PayslipItem(name: e['name'], amount: (e['amount'] as num).toDouble()))
            .toList(),
        deductions: (p['deductions'] as List)
            .map((e) => PayslipItem(name: e['name'], amount: (e['amount'] as num).toDouble()))
            .toList(),
        paid: ((p['paid'] ?? []) as List)
            .map((e) => PayslipPaidItem(
                  paymentType: e['payment_type'] ?? '',
                  period: e['period'] ?? '',
                  document: e['document'] ?? '',
                  date: e['date'] ?? '',
                  amount: (e['amount'] as num).toDouble(),
                ))
            .toList(),
        benefits: ((p['benefits'] ?? []) as List)
            .map((e) => PayslipItem(name: e['name'], amount: (e['amount'] as num).toDouble()))
            .toList(),
        reference: ((p['reference'] ?? []) as List)
            .map((e) => PayslipItem(name: e['name'], amount: (e['amount'] as num).toDouble()))
            .toList(),
        totalAccruals: (p['total_accruals'] as num).toDouble(),
        totalDeductions: (p['total_deductions'] as num).toDouble(),
        totalPaid: ((p['total_paid'] ?? 0) as num).toDouble(),
        netPay: (p['net_pay'] as num).toDouble(),
        debtStart: ((p['debt_start'] ?? 0) as num).toDouble(),
        debtEnd: ((p['debt_end'] ?? 0) as num).toDouble(),
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
