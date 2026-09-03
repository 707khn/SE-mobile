import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Последний удавшийся ответ сервера, сохранённый на телефоне.
///
/// На заводе связь есть не везде: в цеху телефон может не ловить, а меню или
/// внутренний номер нужны именно там. Раньше в таком месте экран показывал
/// ошибку и пустоту — теперь показывает то, что успел получить, с пометкой,
/// когда это было.
///
/// Лежит в обычном shared_preferences, не в защищённом хранилище: здесь меню
/// столовой и справочник, то есть то, что и так висит на стене. Расчётные
/// листки сюда тоже попадают, но телефон шифрует память целиком, а вход в
/// приложение всё равно спрашивают.
class OfflineCache {
  static const String _prefix = 'offline_';

  /// Когда ответ был получен. Приложение показывает это в пометке.
  static const String stampKey = 'cached_at';

  static Future<void> save(String key, Map<String, dynamic> body) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final copy = Map<String, dynamic>.from(body)
        ..[stampKey] = DateTime.now().toIso8601String();
      await prefs.setString('$_prefix$key', jsonEncode(copy));
    } catch (_) {
      // Не сохранилось — не беда: в следующий раз возьмём с сервера.
    }
  }

  /// Сохранённый ответ или null. К нему добавлен [stampKey] — по нему видно,
  /// что данные не свежие.
  static Future<Map<String, dynamic>?> read(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_prefix$key');
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Чистит всё сохранённое. Вызывается при выходе из учётной записи: на
  /// одном телефоне может войти другой человек, и чужой листок он видеть
  /// не должен.
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }
}

/// Время получения из сохранённого ответа, или null у свежего.
DateTime? cachedAt(Map<String, dynamic>? body) {
  final raw = body?[OfflineCache.stampKey];
  if (raw is! String) return null;
  return DateTime.tryParse(raw);
}
