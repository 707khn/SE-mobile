import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'app_version.dart';
import 'variables.dart';

/// Ответ сервера на отчёт: код или null, если связи не было.
typedef CrashSender = Future<int?> Function(Map<String, dynamic> report);

/// Отправка ошибок приложения на сервер.
///
/// Журнал в «О программе» читает только тот, кто сам догадался его
/// переслать, — то есть почти никто. Теперь ошибка уходит на сервер сама, и
/// администратор видит, что падает и на какой сборке, раньше первой жалобы.
///
/// Отчёт сначала кладётся в очередь на телефоне: в цеху связи может не
/// быть, а приложение после падения может и не успеть ничего отправить.
/// Очередь разбирается сразу и при следующем запуске.
///
/// Из текста вычищается то, что для поиска причины не нужно: длинные числа
/// (ИИН, табельный, телефон), почта, пропуск. Сервер чистит ещё раз — на
/// случай старой сборки.
class CrashReport {
  CrashReport._();

  static const String _queueKey = 'crashQueue';
  static const String _installKey = 'installId';

  /// Больше этого в очереди не держим: если связи нет неделю, старые
  /// отчёты всё равно уже ничего не скажут.
  static const int _queueMax = 10;

  /// Сколько отчётов за один запуск. Ошибка отрисовки повторяется на
  /// каждом кадре, и без предела телефон отправлял бы их по кругу.
  static const int _perRun = 10;

  static int _sentThisRun = 0;
  static final Set<String> _seenThisRun = <String>{};
  static bool _flushing = false;

  /// Отправлять ли вообще. В отладочной сборке — нет: ошибки на столе
  /// разработчика серверу не нужны. Проверки включают сами.
  @visibleForTesting
  static bool enabled = kReleaseMode;

  @visibleForTesting
  static CrashSender sender = _post;

  @visibleForTesting
  static void resetForTest() {
    _sentThisRun = 0;
    _seenThisRun.clear();
    _flushing = false;
  }

  static final RegExp _bearer =
      RegExp(r'bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false);
  static final RegExp _email = RegExp(r'[\w.+-]+@[\w-]+\.[\w.-]+');
  static final RegExp _phone = RegExp(r'\+?\d[\d\s()-]{8,}\d');
  static final RegExp _longNumber = RegExp(r'\d{5,}');

  /// Текст без того, что может указать на человека.
  static String scrub(String text) => text
      .replaceAll(_bearer, 'Bearer ***')
      .replaceAll(_email, '***@***')
      .replaceAll(_phone, '***')
      .replaceAll(_longNumber, '***');

  /// Поставить ошибку в очередь и попробовать отправить. Не бросает.
  static Future<void> report(
      {required String error, String stack = '', String where = ''}) async {
    if (!enabled) return;
    try {
      final key = '$error\n$where';
      if (_seenThisRun.contains(key) || _sentThisRun >= _perRun) return;
      _seenThisRun.add(key);
      _sentThisRun++;

      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList(_queueKey) ?? <String>[];
      queue.add(jsonEncode({
        'error': _cut(scrub(error), 500),
        'stack': _cut(scrub(stack), 2000),
        'where': _cut(scrub(where), 100),
        'version': appVersionLabel(),
        'platform': _cut(_platform(), 60),
        'install': await _installId(prefs),
      }));
      final start = queue.length > _queueMax ? queue.length - _queueMax : 0;
      await prefs.setStringList(_queueKey, queue.sublist(start));
    } catch (_) {
      return;
    }
    await flush();
  }

  /// Отправить всё, что накопилось. Связи нет — оставим до следующего раза.
  static Future<void> flush() async {
    if (!enabled || _flushing) return;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList(_queueKey) ?? <String>[];
      final left = <String>[];
      for (var i = 0; i < queue.length; i++) {
        Map<String, dynamic> body;
        try {
          body = jsonDecode(queue[i]) as Map<String, dynamic>;
        } catch (_) {
          continue; // испорченную запись не отправить никогда
        }
        final status = await sender(body);
        // Нет связи или сервер занят — попробуем позже, и остальные тоже.
        if (status == null || status == 429 || status >= 500) {
          left.addAll(queue.sublist(i));
          break;
        }
        // Остальное (принят, отказ по форме) — повторять незачем.
      }
      await prefs.setStringList(_queueKey, left);
    } catch (_) {
      // Ошибка в отправке ошибок не должна ничего ронять.
    } finally {
      _flushing = false;
    }
  }

  static Future<int?> _post(Map<String, dynamic> report) async {
    try {
      final r = await http
          .post(Uri.parse('${AppValues.baseUrl}/api/crash'),
              headers: await authHeaders(), body: jsonEncode(report))
          .timeout(const Duration(seconds: 10));
      return r.statusCode;
    } catch (_) {
      return null;
    }
  }

  /// Случайный номер этой установки. Не связан ни с телефоном, ни с
  /// человеком: по нему сервер лишь отличает один телефон от другого, пока
  /// человек не вошёл.
  static Future<String> _installId(SharedPreferences prefs) async {
    final have = prefs.getString(_installKey);
    if (have != null && have.length >= 8) return have;
    final rnd = Random.secure();
    final id = List.generate(16, (_) => rnd.nextInt(16).toRadixString(16)).join();
    await prefs.setString(_installKey, id);
    return id;
  }

  static String _platform() {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return '';
    }
  }

  static String _cut(String text, int limit) =>
      text.length <= limit ? text : text.substring(0, limit);
}
