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

  test('браузер на компьютере называется браузером и системой', () {
    expect(
        describeUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36'),
        'Chrome, Windows');
    expect(
        describeUserAgent('Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36 '
            'Edg/131.0'),
        'Edge, Windows');
    expect(
        describeUserAgent('Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15'),
        'Safari, macOS');
    expect(describeUserAgent('что-то странное'), 'Браузер');
  });
}
