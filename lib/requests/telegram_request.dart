import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

/// Предлагать ли уведомления в Telegram на этом устройстве.
///
/// Только в браузере: им открывают SE-mobile на iPhone, а уведомлений на
/// телефон у веб-версии нет. На Android уведомления приходят пушем, и
/// Telegram задвоил бы каждое.
bool get telegramOffered => debugTelegramOfferedOverride ?? kIsWeb;

/// Для тестов: `true` или `false` — притвориться, `null` — как на самом деле.
bool? debugTelegramOfferedOverride;

/// Уведомления в Telegram глазами приложения.
class TelegramState {
  const TelegramState({required this.enabled, required this.linked});

  /// На сервере заведён бот. Нет — строки в «Настройках» не показываем.
  final bool enabled;

  /// Telegram у этого человека подключён.
  final bool linked;

  factory TelegramState.fromJson(Map<String, dynamic> json) => TelegramState(
        enabled: json['enabled'] == true,
        linked: json['enabled'] == true && json['linked'] == true,
      );
}

/// Подключён ли Telegram. Не ответил сервер — [LoadFailure].
///
/// Сервер, который о Telegram не знает (старый, 404), отвечает «выключено»:
/// предлагать человеку то, чего сервер не умеет, незачем.
Future<TelegramState> fetchTelegramState() async {
  final http.Response response;
  try {
    response = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/telegram'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 15));
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
  if (await handledUnauthorized(response)) {
    throw const LoadFailure(LoadProblem.denied, 'HTTP 401');
  }
  if (response.statusCode == 404) {
    return const TelegramState(enabled: false, linked: false);
  }
  if (response.statusCode != 200) {
    throw LoadFailure(problemForStatus(response.statusCode),
        'HTTP ${response.statusCode}');
  }
  try {
    final body = jsonDecode(response.body);
    if (body is Map<String, dynamic> && body['message'] == 'Success') {
      return TelegramState.fromJson(body);
    }
  } catch (_) {}
  throw const LoadFailure(LoadProblem.server, 'не JSON');
}

/// Одноразовая ссылка на бота — или почему её нет.
class TelegramLink {
  const TelegramLink({this.url, this.lifetime = Duration.zero, this.problem, this.error});

  /// https://t.me/<бот>?start=<код>. null — не вышло.
  final String? url;

  /// Сколько ссылка живёт.
  final Duration lifetime;

  /// Почему не вышло — как у остальных запросов.
  final LoadProblem? problem;

  /// Слово сервера: `telegram_unavailable` — до Telegram он сейчас не
  /// достучался, `not_configured` — бот на сервере не заведён.
  final String? error;
}

Future<TelegramLink> requestTelegramLink() async {
  try {
    final response = await http
        .post(Uri.parse('${AppValues.baseUrl}/api/telegram/link'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 30));
    if (await handledUnauthorized(response)) return const TelegramLink();
    Map<String, dynamic> body = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {}
    final url = body['url'];
    // Открываем только ссылку на Telegram: что бы ни пришло в ответе, другой
    // сайт из этой кнопки не откроется.
    if (response.statusCode == 200 &&
        url is String &&
        url.startsWith('https://t.me/')) {
      return TelegramLink(
        url: url,
        lifetime:
            Duration(seconds: (body['expires_in'] as num?)?.toInt() ?? 1800),
      );
    }
    return TelegramLink(
      problem: problemForStatus(response.statusCode),
      error: body['error'] as String?,
    );
  } catch (e) {
    return TelegramLink(problem: problemOf(e));
  }
}

/// Отключить. (true, null) — отключено; иначе — почему нет.
Future<(bool, LoadProblem?)> unlinkTelegram() async {
  try {
    final response = await http
        .delete(Uri.parse('${AppValues.baseUrl}/api/telegram'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) return (false, null);
    if (response.statusCode != 200) {
      return (false, problemForStatus(response.statusCode));
    }
    return (true, null);
  } catch (e) {
    return (false, problemOf(e));
  }
}
