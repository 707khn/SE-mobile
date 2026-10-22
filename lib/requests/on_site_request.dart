import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

/// Один человек отдела на сегодня.
class OnSitePerson {
  const OnSitePerson({
    required this.id,
    required this.name,
    required this.status,
    this.title = '',
    this.department = '',
    this.firstIn,
    this.lastOut,
    this.late = false,
    this.awayReason,
    this.awayUntil,
    this.deputy = '',
  });

  final String id;
  final String name;
  final String title;
  final String department;

  /// inside, left, away, absent, not_yet (смена ещё не началась).
  final String status;
  final String? firstIn;
  final String? lastOut;
  final bool late;
  final String? awayReason;
  final DateTime? awayUntil;
  final String deputy;

  /// Нет и ничего не известно — тем и звонить.
  bool get unknown => status == 'absent' || status == 'not_yet';

  factory OnSitePerson.fromJson(Map<String, dynamic> json) {
    final away = json['away'];
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    return OnSitePerson(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      title: '${json['title'] ?? ''}',
      department: '${json['department'] ?? ''}',
      status: '${json['status'] ?? 'absent'}',
      firstIn: text(json['first_in']),
      lastOut: text(json['last_out']),
      late: json['late'] == true,
      awayReason: away is Map ? text(away['reason']) : null,
      awayUntil:
          away is Map ? DateTime.tryParse('${away['until'] ?? ''}') : null,
      deputy: away is Map ? '${away['deputy'] ?? ''}' : '',
    );
  }
}

class OnSiteDay {
  const OnSiteDay({
    required this.people,
    this.counts = const {},
    this.now = '',
    this.shiftStart = '08:00',
    this.lastEvent,
  });

  final List<OnSitePerson> people;
  final Map<String, int> counts;
  final String now;
  final String shiftStart;

  /// Последнее событие турникета за сегодня; null — СКУД сегодня молчит.
  final DateTime? lastEvent;

  int count(String key) => counts[key] ?? 0;

  factory OnSiteDay.fromJson(Map<String, dynamic> json) {
    final counts = json['counts'];
    return OnSiteDay(
      people: ((json['people'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => OnSitePerson.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      counts: counts is Map
          ? {
              for (final e in counts.entries)
                if (e.value is num) '${e.key}': (e.value as num).toInt()
            }
          : const {},
      now: '${json['now'] ?? ''}',
      shiftStart: '${json['shift_start'] ?? '08:00'}',
      lastEvent: DateTime.tryParse('${json['last_event'] ?? ''}'),
    );
  }
}

Future<OnSiteDay> fetchOnSite() async {
  try {
    final response = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/attendance/now'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    return OnSiteDay.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}
