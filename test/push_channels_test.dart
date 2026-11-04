import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Каналы уведомлений называют двое: сервер (какой канал у пуша) и
/// приложение (какие каналы создать на телефоне). Разойдутся — и при
/// закрытом приложении Android положит уведомление в общий канал, а
/// выключить «Столовую», не выключив «Зарплату», станет нельзя. Заметить это
/// можно только на телефоне, с настроенным Firebase, — то есть никогда.
void main() {
  Set<String> channels(String source) =>
      RegExp(r"'([a-z]+_channel)'").allMatches(source).map((m) => m[1]!).toSet();

  test('сервер и приложение называют одни и те же каналы', () {
    final app = File('lib/services/fcm_service.dart').readAsStringSync();
    final server = File('se-mobile-backend/app.py').readAsStringSync();
    final start = server.indexOf('_PUSH_CHANNELS = {');
    final end = server.indexOf("_PUSH_DEFAULT_CHANNEL = 'general_channel'");
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));

    final onServer = channels(server.substring(start, end + 60));
    expect(onServer, isNotEmpty);
    expect(channels(app), equals(onServer));
  });

  test('значок уведомлений Firebase есть и назначен', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest,
        contains('com.google.firebase.messaging.default_notification_icon'));
    expect(manifest, contains('@drawable/ic_stat_notify'));
    expect(
        File('android/app/src/main/res/drawable/ic_stat_notify.xml')
            .existsSync(),
        isTrue);
  });
}
