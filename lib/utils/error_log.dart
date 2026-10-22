import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';
import 'crash_report.dart';

/// Журнал последних ошибок приложения — на самом телефоне.
///
/// Когда приложение падает у человека в цехе, к телефону не подключишься
/// отладчиком: причину приходится угадывать по двум-трём сборкам подряд.
/// Здесь она записывается сразу и показывается в «О программе», откуда её
/// можно отправить одним касанием, — и уходит на сервер сама (CrashReport).
///
/// Храним пять последних: больше никто не читает, а места и так немного.
/// Лежит в обычных настройках, а не в защищённом хранилище: это не секрет,
/// и доставать её должно быть просто.
class ErrorLog {
  ErrorLog._();

  static const String _key = 'errorLog';
  static const int _keep = 5;

  /// Записывает ошибку. Сама никогда не бросает: журнал ошибок, падающий от
  /// ошибки, — худшее, что можно придумать.
  static Future<void> record(Object error, StackTrace? stack,
      {String where = ''}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = prefs.getStringList(_key) ?? <String>[];
      entries.insert(
          0,
          jsonEncode({
            'at': DateTime.now().toIso8601String(),
            'version': appVersionLabel(),
            'where': where,
            'error': error.toString(),
            // Первые строки следа: в них видно место, дальше идёт служебное.
            'stack': _head(stack),
          }));
      await prefs.setStringList(_key, entries.take(_keep).toList());
    } catch (_) {
      // Не записалось — значит, не записалось.
    }
    // И на сервер: из «О программе» её пересылают редко, а знать о ней надо.
    await CrashReport.report(
        error: error.toString(), stack: _head(stack), where: where);
  }

  static Future<List<ErrorEntry>> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_key) ?? <String>[])
          .map((raw) {
            try {
              return ErrorEntry.fromJson(
                  jsonDecode(raw) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<ErrorEntry>()
          .toList();
    } catch (_) {
      return <ErrorEntry>[];
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }

  static String _head(StackTrace? stack, {int lines = 8}) {
    if (stack == null) return '';
    final text = stack.toString().trim().split('\n');
    return text.take(lines).join('\n');
  }
}

class ErrorEntry {
  ErrorEntry({
    required this.at,
    required this.version,
    required this.where,
    required this.error,
    required this.stack,
  });

  final String at;
  final String version;
  final String where;
  final String error;
  final String stack;

  factory ErrorEntry.fromJson(Map<String, dynamic> json) => ErrorEntry(
        at: (json['at'] as String?) ?? '',
        version: (json['version'] as String?) ?? '',
        where: (json['where'] as String?) ?? '',
        error: (json['error'] as String?) ?? '',
        stack: (json['stack'] as String?) ?? '',
      );

  /// То, что уходит в поддержку: всё, что нужно, и ничего, что нельзя
  /// прочитать глазами.
  String asText() {
    final when = at.replaceFirst('T', ' ').split('.').first;
    return [
      'SE Mobile $version',
      'Когда: $when',
      if (where.isNotEmpty) 'Где: $where',
      'Ошибка: $error',
      if (stack.isNotEmpty) 'След:\n$stack',
    ].join('\n');
  }
}
