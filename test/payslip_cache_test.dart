import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/payslip_request.dart';

/// Сохранённые листки. Сервер в тестовой среде отвечает ошибкой на любой
/// запрос — как nginx, когда служба лежит.
void main() {
  Map<String, dynamic> slip(String employee) => {
        'message': 'Success',
        'cached_at': DateTime(2026, 10, 1).toIso8601String(),
        'payslip': {
          'period': 'июль 2026',
          'employee': employee,
          'accruals': [],
          'deductions': [],
          'total_accruals': 100.0,
          'total_deductions': 10.0,
          'net_pay': 90.0,
        },
      };

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({'employeeId': 'OWN0001'});
  });

  testWidgets('свой листок без сервера — из копии', (tester) async {
    SharedPreferences.setMockInitialValues({
      'offline_payslip_OWN0001_2026_07': jsonEncode(slip('Свой Тест')),
    });
    final data = await tester.runAsync(() => fetchPayslip('07', '2026'));
    expect(data!.employee, 'Свой Тест');
    expect(data.cachedAt, isNotNull);
  });

  testWidgets('чужой листок из копии не берётся, даже если своя есть',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'offline_payslip_OWN0001_2026_07': jsonEncode(slip('Свой Тест')),
    });
    Object? error;
    await tester.runAsync(() async {
      try {
        await fetchPayslip('07', '2026', employeeId: 'OTHER0002');
      } catch (e) {
        error = e;
      }
    });
    expect(error, isA<PayslipException>());
  });

  testWidgets('копия под старым ключом без табельного не используется',
      (tester) async {
    // Так листок лежал раньше — им мог оказаться и чужой.
    SharedPreferences.setMockInitialValues({
      'offline_payslip_2026_07': jsonEncode(slip('Чужой Тест')),
    });
    Object? error;
    await tester.runAsync(() async {
      try {
        await fetchPayslip('07', '2026');
      } catch (e) {
        error = e;
      }
    });
    expect(error, isA<PayslipException>());
  });
}
