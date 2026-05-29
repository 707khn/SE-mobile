import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';

enum PayslipErrorKind { timeout, network, notFound }

class PayslipException implements Exception {
  final PayslipErrorKind kind;
  const PayslipException(this.kind);
}

class PayslipItem {
  final String name;
  final double amount;
  const PayslipItem({required this.name, required this.amount});
}

class PayslipPaidItem {
  final String paymentType;
  final String period;
  final String document;
  final String date;
  final double amount;
  const PayslipPaidItem({
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

  const PayslipData({
    required this.period,
    required this.employee,
    required this.position,
    required this.department,
    required this.accruals,
    required this.deductions,
    required this.paid,
    required this.benefits,
    required this.reference,
    required this.totalAccruals,
    required this.totalDeductions,
    required this.totalPaid,
    required this.netPay,
    required this.debtStart,
    required this.debtEnd,
  });
}

// Re-authenticates via /login to get a fresh employee_id for the current backend.
// Falls back to the cached value if the network call fails.
Future<String?> _freshEmployeeId() async {
  final iin = await SecureStorageHelper.instance.getLogin();
  if (iin != null && iin.isNotEmpty) {
    try {
      final r = await http
          .post(
            Uri.parse('${AppValues.baseUrl}/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'iin': iin}),
          )
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        final b = jsonDecode(r.body) as Map<String, dynamic>;
        if (b['message'] == 'Success') {
          final id = (b['employee_id'] as String?) ?? '';
          if (id.isNotEmpty) {
            await SecureStorageHelper.instance.saveEmployeeId(id);
            return id;
          }
        }
      }
    } catch (_) {}
  }
  return SecureStorageHelper.instance.getEmployeeId();
}

PayslipItem _toItem(dynamic e) {
  final m = e as Map;
  return PayslipItem(
    name: m['name'] as String,
    amount: (m['amount'] as num).toDouble(),
  );
}

Future<PayslipData> fetchPayslip(String month, String year, {int _attempt = 0}) async {
  // Re-authenticate on every attempt so a fresh employee_id is used after wake-up.
  final employeeId = await _freshEmployeeId();
  if (employeeId == null || employeeId.isEmpty) {
    throw const PayslipException(PayslipErrorKind.notFound);
  }

  final http.Response response;
  try {
    response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/payslip'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'key_suffix': employeeId, 'month': month, 'year': year}),
        )
        .timeout(const Duration(seconds: 50));
  } on TimeoutException {
    throw const PayslipException(PayslipErrorKind.timeout);
  } catch (_) {
    // Render.com free tier closes connections during cold-start.
    // One automatic retry after 20 s gives the server time to wake up.
    if (_attempt < 1) {
      await Future.delayed(const Duration(seconds: 20));
      return fetchPayslip(month, year, _attempt: _attempt + 1);
    }
    throw const PayslipException(PayslipErrorKind.network);
  }

  if (response.statusCode != 200) {
    throw const PayslipException(PayslipErrorKind.network);
  }

  final body = jsonDecode(response.body) as Map<String, dynamic>;
  if (body['message'] != 'Success') {
    throw const PayslipException(PayslipErrorKind.notFound);
  }

  final p = body['payslip'] as Map<String, dynamic>;

  return PayslipData(
    period: p['period'] as String,
    employee: p['employee'] as String,
    position: (p['position'] as String?) ?? '',
    department: (p['department'] as String?) ?? '',
    accruals: (p['accruals'] as List).map(_toItem).toList(),
    deductions: (p['deductions'] as List).map(_toItem).toList(),
    paid: ((p['paid'] ?? []) as List).map((e) {
      final m = e as Map;
      return PayslipPaidItem(
        paymentType: (m['payment_type'] as String?) ?? '',
        period: (m['period'] as String?) ?? '',
        document: (m['document'] as String?) ?? '',
        date: (m['date'] as String?) ?? '',
        amount: (m['amount'] as num).toDouble(),
      );
    }).toList(),
    benefits: ((p['benefits'] ?? []) as List).map(_toItem).toList(),
    reference: ((p['reference'] ?? []) as List).map(_toItem).toList(),
    totalAccruals: (p['total_accruals'] as num).toDouble(),
    totalDeductions: (p['total_deductions'] as num).toDouble(),
    totalPaid: ((p['total_paid'] ?? 0) as num).toDouble(),
    netPay: (p['net_pay'] as num).toDouble(),
    debtStart: ((p['debt_start'] ?? 0) as num).toDouble(),
    debtEnd: ((p['debt_end'] ?? 0) as num).toDouble(),
  );
}
