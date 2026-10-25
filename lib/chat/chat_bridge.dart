import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show InAppWebViewController, WebStorageManager;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/biometric.dart';
import '../utils/shell_tab.dart';
import 'chat_config.dart';

/// Мост между вкладкой «Чат» и клиентом SE-chat внутри неё.
///
/// Клиент SE-chat — тот же, что на рабочих ПК, со всей своей криптографией.
/// В отдельном приложении SE-chat ему помогают плагины Capacitor; здесь их
/// заменяет обработчик `sechat`: клиент зовёт
/// `flutter_inappwebview.callHandler('sechat', {method, args})` и получает
/// `{ok: true, result}` или `{ok: false, error}`. Список методов — в SE-chat,
/// docs/MOBILE.md, раздел «Вкладка „Чат“ в SE-mobile».
///
/// Что сюда приходит: зашифрованные под ПИН ключи (как есть, расшифровать их
/// здесь нечем), случайный секрет устройства для Keystore, токен канала
/// уведомлений, число непрочитанных и вложение, которое сотрудник сам
/// открыл. Ни пароля чата, ни переписки, ни имён SE-mobile не видит — и на
/// свой сервер ничего из этого не отправляет.
class ChatBridge {
  ChatBridge._();

  /// Номер вкладки «Чат» в нижнем меню.
  static const int tabIndex = 5;

  static const MethodChannel _channel = MethodChannel('se_mobile/chat');

  /// То же хранилище, что у пропуска и кода SE-mobile: Android Keystore. И
  /// стирается оно при выходе тем же deleteAll.
  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const String _prefPrefix = 'sechat.';
  static const String _securePrefix = 'sechat:';

  /// Непрочитанные — для значка на вкладке.
  static final ValueNotifier<int> unread = ValueNotifier<int>(0);

  /// Открытая страница чата. null — вкладку ещё не открывали.
  static InAppWebViewController? controller;

  static bool _listening = false;

  /// Слушать нажатия на уведомления чата. Вызывается из оболочки.
  static Future<void> start() async {
    if (!chatEnabled || _listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openChat') ShellTab.open(tabIndex);
    });
    // Приложение запустили нажатием на уведомление — до того, как Dart был
    // готов это услышать.
    if (await _invoke<bool>('takeOpenRequest') == true) ShellTab.open(tabIndex);
  }

  /// Обработчик вызовов клиента SE-chat.
  static Future<Map<String, dynamic>> handle(List<dynamic> arguments) async {
    try {
      final call = arguments.isNotEmpty && arguments.first is Map
          ? Map<String, dynamic>.from(arguments.first as Map)
          : const <String, dynamic>{};
      final method = call['method'] as String? ?? '';
      final args = call['args'] is Map
          ? Map<String, dynamic>.from(call['args'] as Map)
          : const <String, dynamic>{};
      return {'ok': true, 'result': await _dispatch(method, args)};
    } catch (e) {
      return {'ok': false, 'error': _message(e)};
    }
  }

  static Future<Object?> _dispatch(String method, Map<String, dynamic> args) async {
    switch (method) {
      case 'prefs.get':
        return (await SharedPreferences.getInstance())
            .getString(_prefPrefix + _key(args, 'key'));
      case 'prefs.set':
        await (await SharedPreferences.getInstance())
            .setString(_prefPrefix + _key(args, 'key'), args['value'] as String? ?? '');
        return null;
      case 'prefs.remove':
        await (await SharedPreferences.getInstance()).remove(_prefPrefix + _key(args, 'key'));
        return null;

      case 'secure.get':
        return _secure.read(key: _securePrefix + _key(args, 'name'));
      case 'secure.set':
        await _secure.write(
            key: _securePrefix + _key(args, 'name'), value: args['value'] as String? ?? '');
        return null;
      case 'secure.remove':
        await _secure.delete(key: _securePrefix + _key(args, 'name'));
        return null;

      case 'biometry.check':
        final available = await Biometric.instance.available();
        return {'available': available, 'label': available ? 'отпечаток пальца' : ''};
      case 'biometry.authenticate':
        return Biometric.instance
            .authenticate(args['reason'] as String? ?? 'Разблокировка чата');

      case 'notify.status':
        if (!chatBackgroundNotifyAvailable) {
          return {'running': false, 'permitted': false, 'batteryExempt': false};
        }
        return await _invoke<Map>('status');
      case 'notify.start':
        _requireNotify();
        // Канал уведомлений — только к своему серверу чата.
        if (args['serverUrl'] != kChatUrl) throw StateError('Чужой адрес сервера');
        await _invoke('start', {'serverUrl': kChatUrl, 'token': args['token']});
        return null;
      case 'notify.stop':
        if (chatBackgroundNotifyAvailable) await _invoke('stop');
        return null;
      case 'notify.requestPermission':
        if (!chatBackgroundNotifyAvailable) return {'granted': false};
        return await _invoke<Map>('requestPermission');
      case 'notify.requestBatteryExemption':
        _requireNotify();
        await _invoke('requestBatteryExemption');
        return null;

      case 'file.save':
        return _openFile(args);

      case 'unread':
        final count = args['count'];
        unread.value = count is num && count > 0 ? count.toInt() : 0;
        return null;
    }
    throw UnsupportedError('Неизвестный вызов: $method');
  }

  /// Чат на экране: уведомление о новом сообщении не нужно.
  static Future<void> setVisible(bool visible) async {
    if (!chatEnabled) return;
    await _invoke('setChatVisible', {'visible': visible});
  }

  /// Пока выбрана вкладка «Чат», снимки и запись экрана запрещены.
  static Future<void> setSecure(bool secure) async {
    if (!chatEnabled) return;
    await _invoke('setSecure', {'secure': secure});
  }

  /// Системная «Назад» на вкладке. true — чат обработал сам.
  static Future<bool> back() async {
    final c = controller;
    if (c == null) return false;
    try {
      final handled = await c.evaluateJavascript(
          source: 'window.__seChatBack ? window.__seChatBack() : false');
      return handled == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setTheme(bool dark) async {
    try {
      await controller?.evaluateJavascript(
          source: "window.__seChatTheme && window.__seChatTheme('${dark ? 'dark' : 'light'}')");
    } catch (_) {}
  }

  /// Выход из SE-mobile выводит и из чата.
  ///
  /// Сначала просим сам клиент выйти: он отзовёт сессию на сервере чата и
  /// канал уведомлений. Затем стираем всё, что чат оставил на телефоне, —
  /// даже если страница не ответила: следующий, кто войдёт в SE-mobile на
  /// этом телефоне, не должен получить чужую переписку по чужому ПИН-коду.
  static Future<void> wipe() async {
    if (!chatEnabled) return;
    try {
      await controller
          ?.callAsyncJavaScript(
              functionBody: 'if (window.__seChatLogout) await window.__seChatLogout();')
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
    controller = null;
    unread.value = 0;

    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().where((k) => k.startsWith(_prefPrefix)).toList()) {
        await prefs.remove(key);
      }
      final all = await _secure.readAll();
      for (final key in all.keys.where((k) => k.startsWith(_securePrefix))) {
        await _secure.delete(key: key);
      }
    } catch (_) {}
    await _clearFiles();
    if (chatBackgroundNotifyAvailable) await _invoke('stop');
    // Сессия чата (refresh-токен) лежит в хранилище самой страницы.
    try {
      await WebStorageManager.instance().deleteAllData();
      await InAppWebViewController.clearAllCache();
    } catch (_) {}
  }

  /// Вложение из переписки, уже расшифрованное клиентом чата.
  ///
  /// Во встроенном браузере обычное «скачать» не работает: файл существует
  /// только в памяти страницы. Поэтому клиент передаёт его сюда, а SE-mobile
  /// открывает его в подходящей программе, а если такой нет — предлагает
  /// «Поделиться» (сохранить в «Файлы», отправить себе).
  ///
  /// Лежит файл во временной папке приложения, и не дольше, чем нужно:
  /// прежние стираются при следующем открытии и при выходе из SE-mobile.
  static Future<Map<String, dynamic>> _openFile(Map<String, dynamic> args) async {
    final data = args['data'];
    if (data is! String || data.isEmpty) throw ArgumentError('Не передан файл');
    // «Какие-то байты» — не подсказка: пусть программу выберет расширение.
    final given = args['mime'] is String ? (args['mime'] as String).trim() : '';
    final mime = given.isEmpty || given == 'application/octet-stream' ? null : given;

    final root = await _filesDir();
    await _clearFiles(root);
    final dir = Directory('${root.path}/${DateTime.now().microsecondsSinceEpoch}');
    await dir.create(recursive: true);
    final file = File('${dir.path}/${safeFileName(args['name'])}');
    await file.writeAsBytes(base64Decode(data), flush: true);

    final opened = await OpenFile.open(file.path, type: mime);
    if (opened.type == ResultType.done) return {'opened': true};
    if (opened.type != ResultType.noAppToOpen) throw StateError('Не удалось открыть файл');
    await Share.shareXFiles([XFile(file.path, mimeType: mime)]);
    return {'opened': false, 'shared': true};
  }

  static Future<Directory> _filesDir() async =>
      Directory('${(await getTemporaryDirectory()).path}/sechat-files');

  static Future<void> _clearFiles([Directory? root]) async {
    try {
      final dir = root ?? await _filesDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Файл ещё открыт в другой программе — сотрётся в следующий раз.
    }
  }

  /// Имя вложения пишет отправитель: от него остаётся только имя файла, без
  /// пути и без знаков, которых не любит файловая система.
  @visibleForTesting
  static String safeFileName(Object? raw) {
    var name = raw is String ? raw : '';
    name = name.split(RegExp(r'[\\/]')).last;
    name = name.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_').trim();
    while (name.startsWith('.')) {
      name = name.substring(1);
    }
    if (name.length > 120) {
      final dot = name.lastIndexOf('.');
      final ext = dot > 0 && name.length - dot <= 10 ? name.substring(dot) : '';
      name = name.substring(0, 120 - ext.length) + ext;
    }
    return name.isEmpty ? 'файл' : name;
  }

  static String _key(Map<String, dynamic> args, String name) {
    final value = args[name];
    if (value is! String || value.isEmpty) throw ArgumentError('Не указан $name');
    return value;
  }

  static void _requireNotify() {
    if (!chatBackgroundNotifyAvailable) {
      throw StateError('В этой сборке фоновых уведомлений чата нет');
    }
  }

  static Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  static String _message(Object e) {
    if (e is StateError) return e.message;
    if (e is ArgumentError) return '${e.message}';
    if (e is UnsupportedError) return e.message ?? 'Не поддерживается';
    if (e is PlatformException) return e.message ?? e.code;
    return e.toString();
  }
}
