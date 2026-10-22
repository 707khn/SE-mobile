import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Последний удавшийся ответ сервера, сохранённый на телефоне.
///
/// На заводе связь есть не везде: в цеху телефон может не ловить, а меню или
/// внутренний номер нужны именно там. Раньше в таком месте экран показывал
/// ошибку и пустоту — теперь показывает то, что успел получить, с пометкой,
/// когда это было.
///
/// Меню столовой и справочник — то, что и так висит на стене, — лежат в
/// обычном shared_preferences. Расчётные листки — нет: это зарплата, а
/// shared_preferences — открытый файл, который читается с любого телефона с
/// правами root или из резервной копии, снятой по кабелю. Их кладём
/// с `private: true` в защищённое хранилище, рядом с пропуском (Keystore на
/// Android, Keychain на iOS).
class OfflineCache {
  static const String _prefix = 'offline_';

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Когда ответ был получен. Приложение показывает это в пометке.
  static const String stampKey = 'cached_at';

  /// [private] — личное (расчётный лист): кладём в защищённое хранилище.
  static Future<void> save(String key, Map<String, dynamic> body,
      {bool private = false}) async {
    try {
      final copy = Map<String, dynamic>.from(body)
        ..[stampKey] = DateTime.now().toIso8601String();
      final raw = jsonEncode(copy);
      final prefs = await SharedPreferences.getInstance();
      if (private) {
        await _secure.write(key: '$_prefix$key', value: raw);
        // Копия, оставшаяся открытой от прежних сборок, больше не нужна.
        await prefs.remove('$_prefix$key');
      } else {
        await prefs.setString('$_prefix$key', raw);
      }
    } catch (_) {
      // Не сохранилось — не беда: в следующий раз возьмём с сервера.
    }
  }

  /// Сохранённый ответ или null. К нему добавлен [stampKey] — по нему видно,
  /// что данные не свежие.
  static Future<Map<String, dynamic>?> read(String key,
      {bool private = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? raw;
      if (private) {
        raw = await _secure.read(key: '$_prefix$key');
        // Прежние сборки клали листок в открытый файл. Переносим, чтобы и
        // после обновления без связи он открывался, но уже из защищённого.
        final legacy = prefs.getString('$_prefix$key');
        if (legacy != null) {
          if (raw == null) {
            raw = legacy;
            await _secure.write(key: '$_prefix$key', value: legacy);
          }
          await prefs.remove('$_prefix$key');
        }
      } else {
        raw = prefs.getString('$_prefix$key');
      }
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Оставляет из копий с этим префиксом только [keep] последних по ключу.
  ///
  /// Меню сохраняется под своим ключом на каждый день, и раньше копии не
  /// уходили никогда: за год — триста с лишним дней меню. shared_preferences
  /// держит всё одним файлом, читает его целиком при запуске и целиком же
  /// переписывает при каждом сохранении, так что лишнее замедляет всё
  /// приложение, а не только столовую. Ключи с датой ГГГГ-ММ-ДД сортируются
  /// как строки, поэтому «последние по ключу» — это самые поздние дни.
  ///
  /// [private] — то же для защищённого хранилища: листки тоже сохраняются
  /// по одному на месяц, а ключ «…_ГГГГ_ММ» сортируется так же.
  static Future<void> trim(String prefix,
      {required int keep, bool private = false}) async {
    try {
      final List<String> keys;
      if (private) {
        keys = (await _secure.readAll()).keys.toList();
      } else {
        keys = (await SharedPreferences.getInstance()).getKeys().toList();
      }
      final mine = keys.where((k) => k.startsWith('$_prefix$prefix')).toList()
        ..sort((a, b) => b.compareTo(a));
      for (final key in mine.skip(keep)) {
        if (private) {
          await _secure.delete(key: key);
        } else {
          await (await SharedPreferences.getInstance()).remove(key);
        }
      }
    } catch (_) {}
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
    try {
      final keys = (await _secure.readAll())
          .keys
          .where((k) => k.startsWith(_prefix))
          .toList();
      for (final key in keys) {
        await _secure.delete(key: key);
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
