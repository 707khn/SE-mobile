import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItEvent, ItPerson;

const hazardCategories = [
  'spill',
  'electrical',
  'equipment',
  'fire',
  'height',
  'near_miss',
  'other'
];

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class Hazard {
  const Hazard({
    required this.id,
    required this.category,
    required this.place,
    required this.text,
    this.urgent = false,
    this.status = 'new',
    this.anonymous = false,
    this.author,
    this.assignee,
    this.outcome = '',
    this.createdAt,
    this.events = const [],
    this.isAuthor = false,
    this.canAct = false,
  });

  final int id;
  final String category;
  final String place;
  final String text;
  final bool urgent;

  /// new, in_work, resolved, rejected.
  final String status;
  final bool anonymous;
  final ItPerson? author;
  final ItPerson? assignee;
  final String outcome;
  final DateTime? createdAt;
  final List<ItEvent> events;
  final bool isAuthor;
  final bool canAct;

  bool get isOpen => status == 'new' || status == 'in_work';

  factory Hazard.fromJson(Map<String, dynamic> json) {
    final events = json['events'];
    return Hazard(
      id: (json['id'] as num?)?.toInt() ?? 0,
      category: '${json['category'] ?? 'other'}',
      place: '${json['place'] ?? ''}',
      text: '${json['text'] ?? ''}',
      urgent: json['urgent'] == true,
      status: '${json['status'] ?? 'new'}',
      anonymous: json['anonymous'] == true,
      author: ItPerson.fromJson(json['author']),
      assignee: ItPerson.fromJson(json['assignee']),
      outcome: '${json['outcome'] ?? ''}',
      createdAt: _time(json['created_at']),
      events: events is List
          ? events
              .whereType<Map>()
              .map((e) => ItEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      isAuthor: json['is_author'] == true,
      canAct: json['can_act'] == true,
    );
  }
}

class HazardList {
  const HazardList(
      {required this.items, this.staff = false, this.open = 0, this.fresh = 0});

  final List<Hazard> items;
  final bool staff;
  final int open;

  /// Ещё никто не взял.
  final int fresh;

  factory HazardList.fromJson(Map<String, dynamic> json) => HazardList(
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Hazard.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        staff: json['staff'] == true,
        open: (json['open'] as num?)?.toInt() ?? 0,
        fresh: (json['new'] as num?)?.toInt() ?? 0,
      );
}

class HazardResult {
  const HazardResult({this.item, this.track, this.error, this.problem});

  final Hazard? item;
  final String? track;
  final String? error;
  final LoadProblem? problem;

  bool get ok => item != null;
}

const _tracksKey = 'hazard_tracks';

/// Ключи анонимных сообщений, отправленных с этого телефона.
Future<List<String>> savedHazardTracks() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_tracksKey) ?? const [];
  } catch (_) {
    return const [];
  }
}

Future<void> _saveTrack(String token) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final all = [...(prefs.getStringList(_tracksKey) ?? const <String>[])];
    all.insert(0, token);
    // Сервер принимает не больше 50 за раз — старые отпускаем.
    await prefs.setStringList(_tracksKey, all.take(50).toList());
  } catch (_) {}
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

Future<Map<String, dynamic>> _send(String method, String path,
    [Map<String, Object?>? body]) async {
  try {
    final headers = await authHeaders();
    final response = await (method == 'GET'
            ? http.get(_uri(path), headers: headers)
            : http.post(_uri(path), headers: headers, body: jsonEncode(body)))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

Future<HazardList> fetchHazards({bool queue = false}) async =>
    HazardList.fromJson(
        await _send('GET', '/api/hazards${queue ? '?scope=queue' : ''}'));

Future<Hazard> fetchHazard(int id) async {
  final body = await _send('GET', '/api/hazards/$id');
  return Hazard.fromJson(body['item'] as Map<String, dynamic>);
}

/// Что стало с анонимными сообщениями по их ключам.
Future<List<Hazard>> trackHazards(List<String> tokens) async {
  if (tokens.isEmpty) return const [];
  final body = await _send('POST', '/api/hazards/track', {'tokens': tokens});
  return ((body['items'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Hazard.fromJson(Map<String, dynamic>.from(e)))
      .toList();
}

Future<HazardResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const HazardResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      final track =
          parsed['track'] is String ? parsed['track'] as String : null;
      return HazardResult(
          item: Hazard.fromJson(Map<String, dynamic>.from(parsed['item'])),
          track: track);
    }
    final error = parsed['error'];
    return HazardResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return HazardResult(problem: problemOf(e));
  }
}

Future<HazardResult> reportHazard({
  required String category,
  required String place,
  required String text,
  bool urgent = false,
  bool anonymous = false,
}) async {
  final result = await _post('/api/hazards', {
    'category': category,
    'place': place,
    'text': text,
    if (urgent) 'urgent': true,
    if (anonymous) 'anonymous': true,
  });
  if (result.track != null) await _saveTrack(result.track!);
  return result;
}

/// take, resolve, reject, comment.
Future<HazardResult> hazardAction(int id, String action,
        {String comment = ''}) =>
    _post('/api/hazards/$id', {
      'action': action,
      if (comment.isNotEmpty) 'comment': comment,
    });
