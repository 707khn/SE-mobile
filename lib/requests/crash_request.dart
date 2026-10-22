import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

/// Одна ошибка, собранная со всех телефонов, где она случилась.
class CrashGroup {
  const CrashGroup({
    required this.fingerprint,
    required this.error,
    required this.where,
    required this.stack,
    required this.count,
    required this.people,
    required this.names,
    required this.versions,
    required this.platforms,
    required this.lastAt,
  });

  final String fingerprint;
  final String error;
  final String where;
  final String stack;
  final int count;

  /// У скольких разных людей или телефонов.
  final int people;

  /// Кто из вошедших с ней столкнулся — чтобы было кому позвонить.
  final List<String> names;
  final List<String> versions;
  final List<String> platforms;
  final DateTime? lastAt;

  factory CrashGroup.fromJson(Map<String, dynamic> json) => CrashGroup(
        fingerprint: (json['fingerprint'] as String?) ?? '',
        error: (json['error'] as String?) ?? '',
        where: (json['where'] as String?) ?? '',
        stack: (json['stack'] as String?) ?? '',
        count: (json['count'] as num?)?.toInt() ?? 0,
        people: (json['people'] as num?)?.toInt() ?? 0,
        names: _strings(json['names']),
        versions: _strings(json['versions']),
        platforms: _strings(json['platforms']),
        lastAt: DateTime.tryParse((json['last_at'] as String?) ?? ''),
      );
}

/// Версия приложения: у скольких стоит и у скольких на ней падало.
class CrashVersion {
  const CrashVersion({
    required this.version,
    required this.users,
    required this.crashes,
    required this.people,
  });

  final String version;
  final int users;
  final int crashes;
  final int people;
}

class CrashDay {
  const CrashDay({required this.day, required this.count, required this.people});

  final DateTime? day;
  final int count;
  final int people;
}

class CrashesReport {
  const CrashesReport({
    required this.days,
    required this.versions,
    required this.groups,
    required this.spikePeople,
    required this.spikeUsual,
  });

  final List<CrashDay> days;
  final List<CrashVersion> versions;
  final List<CrashGroup> groups;

  /// Сегодня ошибки у заметно большего числа людей, чем обычно. null — нет.
  final int? spikePeople;
  final double? spikeUsual;

  factory CrashesReport.fromJson(Map<String, dynamic> body) {
    final spike = body['spike'];
    return CrashesReport(
      days: ((body['days'] as List?) ?? const [])
          .whereType<Map>()
          .map((d) => CrashDay(
                day: DateTime.tryParse((d['day'] as String?) ?? ''),
                count: (d['count'] as num?)?.toInt() ?? 0,
                people: (d['people'] as num?)?.toInt() ?? 0,
              ))
          .toList(),
      versions: ((body['versions'] as List?) ?? const [])
          .whereType<Map>()
          .map((v) => CrashVersion(
                version: (v['version'] as String?) ?? '',
                users: (v['users'] as num?)?.toInt() ?? 0,
                crashes: (v['crashes'] as num?)?.toInt() ?? 0,
                people: (v['people'] as num?)?.toInt() ?? 0,
              ))
          .toList(),
      groups: ((body['groups'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CrashGroup.fromJson)
          .toList(),
      spikePeople: spike is Map ? (spike['people'] as num?)?.toInt() : null,
      spikeUsual: spike is Map ? (spike['usual'] as num?)?.toDouble() : null,
    );
  }
}

List<String> _strings(dynamic raw) =>
    raw is List ? raw.whereType<String>().toList() : <String>[];

Future<CrashesReport> fetchCrashes({int days = 14}) async {
  final response = await http
      .get(Uri.parse('${AppValues.baseUrl}/api/admin/crashes?days=$days'),
          headers: await authHeaders())
      .timeout(const Duration(seconds: 20));
  if (response.statusCode != 200) {
    throw LoadFailure(problemForStatus(response.statusCode),
        'HTTP ${response.statusCode}');
  }
  return CrashesReport.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>);
}

/// «Исправлено»: убрать ошибку из списка. Случится снова — появится снова.
Future<bool> forgetCrash(String fingerprint) async {
  try {
    final response = await http
        .delete(
            Uri.parse('${AppValues.baseUrl}/api/admin/crashes/$fingerprint'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 15));
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}
