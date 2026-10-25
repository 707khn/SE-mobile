import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/chat/chat_bridge.dart';
import 'package:se_mobile/chat/chat_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Мост вкладки «Чат»: клиент SE-chat зовёт `sechat` с {method, args} и
/// ждёт {ok, result} или {ok: false, error}. Ошибка не должна ронять
/// страницу — она должна вернуться клиенту ответом.
Future<Map<String, dynamic>> call(String method, [Map<String, dynamic>? args]) =>
    ChatBridge.handle([
      {'method': method, 'args': args ?? <String, dynamic>{}}
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ChatBridge.unread.value = 0;
  });

  test('настройки чата лежат под своим префиксом', () async {
    expect((await call('prefs.set', {'key': 'sechat.lock.meta', 'value': '{}'}))['ok'], isTrue);
    expect((await call('prefs.get', {'key': 'sechat.lock.meta'}))['result'], '{}');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys().every((k) => k.startsWith('sechat.')), isTrue);

    await call('prefs.remove', {'key': 'sechat.lock.meta'});
    expect((await call('prefs.get', {'key': 'sechat.lock.meta'}))['result'], isNull);
  });

  test('счётчик непрочитанных доходит до значка', () async {
    await call('unread', {'count': 3});
    expect(ChatBridge.unread.value, 3);
    await call('unread', {'count': -1});
    expect(ChatBridge.unread.value, 0);
  });

  test('неизвестный вызов — ответ с ошибкой, а не исключение', () async {
    final answer = await call('fs.readAll');
    expect(answer['ok'], isFalse);
    expect(answer['error'], contains('fs.readAll'));
  });

  test('пустой ключ отклоняется', () async {
    expect((await call('prefs.get'))['ok'], isFalse);
  });

  test('канал уведомлений не запускается без чата в сборке', () async {
    // В тестах CHAT_URL не задан: вкладки нет, и службу не запустить ни к
    // какому серверу.
    expect(chatEnabled, isFalse);
    final answer =
        await call('notify.start', {'serverUrl': 'https://evil.example', 'token': 't'});
    expect(answer['ok'], isFalse);
  });

  test('имя вложения не выводит за пределы папки', () {
    expect(ChatBridge.safeFileName('../../shared_prefs/x.xml'), 'x.xml');
    expect(ChatBridge.safeFileName(r'C:\Users\a\отчёт.pdf'), 'отчёт.pdf');
    expect(ChatBridge.safeFileName('.hidden'), 'hidden');
    expect(ChatBridge.safeFileName('a:b*c?.txt'), 'a_b_c_.txt');
    expect(ChatBridge.safeFileName(''), 'файл');
    expect(ChatBridge.safeFileName(null), 'файл');
    final long = ChatBridge.safeFileName('${'я' * 300}.docx');
    expect(long.length, 120);
    expect(long, endsWith('.docx'));
  });

  test('пустое вложение отклоняется', () async {
    final answer = await call('file.save', {'name': 'a.txt', 'data': ''});
    expect(answer['ok'], isFalse);
  });

  test('клиент чата в пакете собран для вкладки', () {
    final index = File('$kChatAssetDir/index.html');
    expect(index.existsSync(), isTrue, reason: 'tools/chat/build-chat.sh');
    final html = index.readAsStringSync();
    // Относительные ссылки — страница открывается по вложенному пути.
    expect(html, contains('src="./assets/'));
    // Политика безопасности — в самой странице: заголовков nginx у неё нет.
    expect(html, contains('Content-Security-Policy'));
    expect(html, contains("script-src 'self'"));
  });
}
