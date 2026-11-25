import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/variables.dart';
import '../utils/api.dart';
import '../utils/load_problem.dart';

/// Одна рассылка из журнала: что, кому и чем кончилось.
class PushLogEntry {
  const PushLogEntry({
    required this.id,
    required this.createdAt,
    required this.kind,
    required this.title,
    required this.body,
    required this.audience,
    required this.people,
    required this.devices,
    required this.delivered,
    required this.failed,
    required this.telegram,
    required this.status,
    required this.note,
    required this.source,
    required this.sentBy,
    required this.recipients,
    required this.date,
  });

  final int id;
  final DateTime? createdAt;

  /// menu, payslip, news, turnstile, general.
  final String kind;
  final String title;
  final String body;

  /// 'all' — всем; 'person' — выбранным.
  final String audience;
  final int people;
  final int devices;
  final int delivered;
  final int failed;
  final int telegram;

  /// 'sent' | 'skipped' | 'error'.
  final String status;
  final String note;

  /// 'auto' — сервер сам; 'manual' — из этой вкладки.
  final String source;
  final String sentBy;

  /// Первые несколько адресатов по имени.
  final List<String> recipients;

  /// Дата меню, если это меню.
  final String date;

  factory PushLogEntry.fromJson(Map<String, dynamic> json) => PushLogEntry(
        id: (json['id'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse((json['created_at'] as String?) ?? '')
            ?.toLocal(),
        kind: (json['kind'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        body: (json['body'] as String?) ?? '',
        audience: (json['audience'] as String?) ?? 'person',
        people: (json['people'] as num?)?.toInt() ?? 0,
        devices: (json['devices'] as num?)?.toInt() ?? 0,
        delivered: (json['delivered'] as num?)?.toInt() ?? 0,
        failed: (json['failed'] as num?)?.toInt() ?? 0,
        telegram: (json['telegram'] as num?)?.toInt() ?? 0,
        status: (json['status'] as String?) ?? 'sent',
        note: (json['note'] as String?) ?? '',
        source: (json['source'] as String?) ?? 'auto',
        sentBy: (json['sent_by'] as String?) ?? '',
        recipients: ((json['recipients'] as List?) ?? const [])
            .map((e) => '$e')
            .toList(),
        date: (json['date'] as String?) ?? '',
      );
}

/// Журнал и заодно — работают ли пуши и Telegram.
class PushLogReport {
  const PushLogReport({
    required this.items,
    required this.kinds,
    required this.pushEnabled,
    required this.pushProblem,
    required this.pushDevices,
    required this.pushPeople,
    required this.telegramEnabled,
    required this.telegramPeople,
  });

  final List<PushLogEntry> items;
  final List<String> kinds;
  final bool pushEnabled;
  final String pushProblem;
  final int pushDevices;
  final int pushPeople;
  final bool telegramEnabled;
  final int telegramPeople;

  factory PushLogReport.fromJson(Map<String, dynamic> json) {
    final push = (json['push'] as Map?) ?? const {};
    final telegram = (json['telegram'] as Map?) ?? const {};
    return PushLogReport(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => PushLogEntry.fromJson(e.cast<String, dynamic>()))
          .toList(),
      kinds: ((json['kinds'] as List?) ?? const []).map((e) => '$e').toList(),
      pushEnabled: push['enabled'] == true,
      pushProblem: (push['problem'] as String?) ?? '',
      pushDevices: (push['devices'] as num?)?.toInt() ?? 0,
      pushPeople: (push['people'] as num?)?.toInt() ?? 0,
      telegramEnabled: telegram['enabled'] == true,
      telegramPeople: (telegram['people'] as num?)?.toInt() ?? 0,
    );
  }
}

Future<PushLogReport> fetchPushLog() async {
  final response = await http
      .get(Uri.parse('${AppValues.baseUrl}/api/admin/notifications?limit=300'),
          headers: await authHeaders())
      .timeout(const Duration(seconds: 30));
  if (await handledUnauthorized(response)) {
    throw const LoadFailure(LoadProblem.denied);
  }
  if (response.statusCode != 200) {
    throw LoadFailure(problemForStatus(response.statusCode),
        'HTTP ${response.statusCode}');
  }
  return PushLogReport.fromJson(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
}

/// Итог отправки: строка журнала или код ошибки сервера (`no_menu`, …).
typedef SendResult = ({PushLogEntry? entry, String error, LoadProblem? problem});

Future<SendResult> _post(String path, Map<String, dynamic> body) async {
  try {
    final response = await http
        .post(Uri.parse('${AppValues.baseUrl}$path'),
            headers: await authHeaders(), body: jsonEncode(body))
        // Рассылка на пятьсот телефонов — несколько секунд у Google.
        .timeout(const Duration(seconds: 60));
    if (await handledUnauthorized(response)) {
      return (entry: null, error: 'unauthorized', problem: LoadProblem.denied);
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final map = decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    if (response.statusCode != 200) {
      return (
        entry: null,
        error: (map['error'] as String?) ?? '',
        problem: problemForStatus(response.statusCode),
      );
    }
    final item = map['item'];
    return (
      entry: item is Map ? PushLogEntry.fromJson(item.cast<String, dynamic>()) : null,
      error: '',
      problem: null,
    );
  } catch (e) {
    return (entry: null, error: '', problem: problemOf(e));
  }
}

/// «Меню на … опубликовано» — ещё раз, вручную.
Future<SendResult> sendMenuNotice(DateTime day) {
  final iso = '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';
  return _post('/api/admin/notifications/menu', {'date': iso});
}

/// Повторить рассылку из журнала тем же людям.
Future<SendResult> resendPush(int id) =>
    _post('/api/admin/notifications/$id/resend', const {});

/// Своё уведомление. [employeeIds] пустой — всем.
Future<SendResult> sendCustomNotice({
  required String title,
  required String body,
  required List<String> employeeIds,
  required bool feed,
}) =>
    _post('/api/admin/notifications/send', {
      'title': title,
      'body': body,
      'audience': employeeIds.isEmpty ? 'all' : 'person',
      'employee_ids': employeeIds,
      'feed': feed,
    });
