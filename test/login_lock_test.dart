import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/login_lock.dart';

void main() {
  test('минуты округляются вверх — «0 мин.» не бывает', () {
    expect(lockMinutes(1), 1);
    expect(lockMinutes(40), 1);
    expect(lockMinutes(60), 1);
    expect(lockMinutes(61), 2);
    expect(lockMinutes(900), 15);
  });

  test('без срока от сервера — без числа', () {
    expect(lockMinutes(null), isNull);
    expect(lockMinutes(0), isNull);
    expect(lockMinutes(-5), isNull);
  });
}
