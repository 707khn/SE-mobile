import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/requests/payslip_request.dart';

PayslipData _slip({
  double accruals = 499441,
  double deductions = 92791,
  double paid = 411748,
  double debtStart = 408748,
  double debtEnd = 403650,
}) =>
    PayslipData(
      period: 'Октябрь 2026',
      employee: 'Тестов Тест',
      position: '',
      department: '',
      accruals: const [],
      deductions: const [],
      paid: const [],
      benefits: const [],
      reference: const [],
      totalAccruals: accruals,
      totalDeductions: deductions,
      totalPaid: paid,
      netPay: accruals - deductions,
      debtStart: debtStart,
      debtEnd: debtEnd,
    );

/// Крупная цифра листка — как внизу листка 1С: долг за организацией на
/// конец месяца, а не «начислено минус удержано».
void main() {
  test('к выплате — долг на конец месяца, с учётом выплат из кассы', () {
    final s = _slip();
    expect(s.hasSettlement, isTrue);
    expect(s.netPay, 406650);
    expect(s.toPay, 403650);
  });

  test('долг за работником — отрицательный', () {
    expect(_slip(debtEnd: -9497).toPay, -9497);
  });

  test('всё выплачено — к выплате ноль', () {
    expect(_slip(debtEnd: 0).toPay, 0);
  });

  test('листок без взаиморасчётов — начислено минус удержано', () {
    final s = _slip(paid: 0, debtStart: 0, debtEnd: 0);
    expect(s.hasSettlement, isFalse);
    expect(s.toPay, 406650);
  });
}
