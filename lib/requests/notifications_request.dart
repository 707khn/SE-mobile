import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

/// Одно оповещение из ленты: «расчётный лист готов», «меню выложено»,
/// объявление.
class AppNotice {
  final int id;

  /// payslip, menu, news, queue — по нему понятно, какой экран открыть.
  final String kind;
  final String title;
  final String body;

  /// На что указывает: номер новости, дата меню.
  final String? ref;
  final DateTime? createdAt;
  final bool unread;

  const AppNotice({
    required this.id,
    required this.kind,
    required this.title,
    this.body = '',
    this.ref,
    this.createdAt,
    this.unread = false,
  });

  static AppNotice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! num) return null;
    return AppNotice(
      id: id.toInt(),
      kind: (raw['kind'] as String?) ?? '',
      title: (raw['title'] as String?) ?? '',
      body: (raw['body'] as String?) ?? '',
      ref: raw['ref']?.toString(),
      createdAt: DateTime.tryParse((raw['created_at'] as String?) ?? ''),
      unread: raw['unread'] == true,
    );
  }
}

/// Что на сервере сломано прямо сейчас — только для администратора.
///
/// Это не строка ленты, а состояние: починили — и с сервера оно больше не
/// приходит.
class SystemProblem {
  final String key;
  final String title;
  final String body;

  const SystemProblem({required this.key, required this.title, this.body = ''});

  static SystemProblem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = (raw['title'] as String?) ?? '';
    if (title.isEmpty) return null;
    return SystemProblem(
      key: (raw['key'] as String?) ?? '',
      title: title,
      body: (raw['body'] as String?) ?? '',
    );
  }
}

class NoticeFeed {
  final List<AppNotice> items;
  final List<SystemProblem> system;
  final int unread;

  const NoticeFeed({
    this.items = const [],
    this.system = const [],
    this.unread = 0,
  });

  /// Самое свежее — до него и отмечаем прочитанным.
  int? get newestId => items.isEmpty ? null : items.first.id;

  static NoticeFeed fromJson(Map<String, dynamic> body) {
    List<T> list<T>(Object? raw, T? Function(Object?) parse) =>
        raw is List ? raw.map(parse).whereType<T>().toList() : <T>[];
    final items = list(body['items'], AppNotice.fromJson)
      ..sort((a, b) => b.id.compareTo(a.id));
    return NoticeFeed(
      items: items,
      system: list(body['system'], SystemProblem.fromJson),
      unread: (body['unread'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Лента целиком. Не загрузилась — причина, а не пустой список: пустая
/// лента и «нет связи» для человека — разные вещи.
Future<({NoticeFeed? feed, LoadProblem? problem})> fetchNotices() async {
  try {
    final response = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/notifications'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return (feed: null, problem: LoadProblem.server);
    }
    if (response.statusCode != 200) {
      return (feed: null, problem: problemForStatus(response.statusCode));
    }
    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic> || body['message'] != 'Success') {
      return (feed: null, problem: LoadProblem.server);
    }
    return (feed: NoticeFeed.fromJson(body), problem: null);
  } catch (e) {
    return (feed: null, problem: problemOf(e));
  }
}

/// Число на колокольчик: непрочитанные плюс — у администратора — поломки.
///
/// Без связи null: колокольчик тогда оставляет прежнее число, а не гасит
/// его, будто всё прочитано.
///
/// Пропуск не годится — тоже null, но на вход не уводим: колокольчик
/// спрашивает сам, в фоне, и выкидывать человека из приложения посреди
/// чтения листка из-за него незачем. Это сделает первый же экран, куда он
/// пойдёт.
Future<int?> fetchUnreadCount() async {
  try {
    final response = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/notifications/unread'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body);
    if (body is! Map || body['message'] != 'Success') return null;
    final unread = (body['unread'] as num?)?.toInt() ?? 0;
    final system = (body['system'] as num?)?.toInt() ?? 0;
    return unread + system;
  } catch (_) {
    return null;
  }
}

/// Отметить прочитанным всё до [lastId] включительно.
Future<bool> markNoticesSeen(int lastId) async {
  try {
    final response = await http
        .post(Uri.parse('${AppValues.baseUrl}/api/notifications/seen'),
            headers: await authHeaders(), body: jsonEncode({'last_id': lastId}))
        .timeout(const Duration(seconds: 10));
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}
