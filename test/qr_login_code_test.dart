import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/requests/qr_login_request.dart';

void main() {
  test('код понимается и из ссылки, и набранным руками', () {
    expect(qrLoginCodeFrom('ABCD2345'), 'ABCD2345');
    expect(qrLoginCodeFrom(' abcd-2345 '), 'ABCD2345');
    expect(qrLoginCodeFrom('abcd 2345'), 'ABCD2345');
    expect(qrLoginCodeFrom('https://api.se-btrz.com/web/?pc=ABCD2345'),
        'ABCD2345');
  });

  test('не код — null', () {
    expect(qrLoginCodeFrom(''), isNull);
    expect(qrLoginCodeFrom('ABC'), isNull);
    // 0, O, 1 и I в коде не бывает.
    expect(qrLoginCodeFrom('ABCD0O1I'), isNull);
    expect(qrLoginCodeFrom('https://example.com/'), isNull);
  });

  test('код для глаз — двумя четвёрками', () {
    expect(qrLoginCodeForEyes('ABCD2345'), 'ABCD 2345');
  });
}
