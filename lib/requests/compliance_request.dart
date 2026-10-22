import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'assignment_request.dart' show AssignPerson;

const complianceKinds = [
  'corruption',
  'conflict',
  'fraud',
  'pressure',
  'other'
];

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class ComplianceMessage {
  const ComplianceMessage(
      {required this.text, this.fromOfficer = false, this.at});

  final String text;
  final bool fromOfficer;
  final DateTime? at;
}

class ComplianceReport {
  const ComplianceReport({
    required this.id,
    required this.kind,
    required this.text,
    this.status = 'new',
    this.resolution = '',
    this.anonymous = false,
    this.createdAt,
    this.messages = const [],
    this.author,
    this.isMine = false,
    this.canReply = false,
    this.canHandle = false,
    this.track,
  });

  final int id;
  final String kind;
  final String text;
  final String status;
  final String resolution;
  final bool anonymous;
  final DateTime? createdAt;
  final List<ComplianceMessage> messages;
  final AssignPerson? author;
  final bool isMine;
  final bool canReply;
  final bool canHandle;

  /// Ключ анонимного сообщения — только на этом телефоне.
  final String? track;

  factory ComplianceReport.fromJson(Map<String, dynamic> json,
          {String? track}) =>
      ComplianceReport(
        id: (json['id'] as num?)?.toInt() ?? 0,
        kind: '${json['kind'] ?? 'other'}',
        text: '${json['text'] ?? ''}',
        status: '${json['status'] ?? 'new'}',
        resolution: '${json['resolution'] ?? ''}',
        anonymous: json['anonymous'] == true,
        createdAt: _time(json['created_at']),
        messages: ((json['messages'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => ComplianceMessage(
                text: '${m['text'] ?? ''}',
                fromOfficer: m['from_officer'] == true,
                at: _time(m['at'])))
            .toList(),
        author: json['author'] is Map
            ? AssignPerson.fromJson(Map<String, dynamic>.from(json['author']))
            : null,
        isMine: json['is_mine'] == true,
        canReply: json['can_reply'] == true,
        canHandle: json['can_handle'] == true,
        track: track,
      );
}

class ComplianceList {
  const ComplianceList(
      {this.officer = false, this.mine = const [], this.queue = const []});

  final bool officer;
  final List<ComplianceReport> mine;
  final List<ComplianceReport> queue;
}

class ComplianceResult {
  const ComplianceResult({this.item, this.error, this.problem});

  final ComplianceReport? item;
  final String? error;
  final LoadProblem? problem;

  bool get ok => item != null;
}

const _tracksKey = 'compliance_tracks';
const _storage = FlutterSecureStorage();

/// Ключи анонимных сообщений — в защищённом хранилище, не в настройках:
/// по ним видно, что человек писал на горячую линию.
Future<List<String>> _tracks() async {
  try {
    final raw = await _storage.read(key: _tracksKey);
    if (raw == null) return const [];
    return (jsonDecode(raw) as List).whereType<String>().toList();
  } catch (_) {
    return const [];
  }
}

Future<void> _saveTrack(String track) async {
  final all = [track, ...await _tracks()];
  await _storage.write(
      key: _tracksKey, value: jsonEncode(all.take(30).toList()));
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

Future<Map<String, dynamic>> _request(String method, String path,
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

List<ComplianceReport> _items(Object? raw, {List<String>? tracks}) =>
    ((raw as List?) ?? const []).whereType<Map>().map((e) {
      final json = Map<String, dynamic>.from(e);
      final index = (json['track_index'] as num?)?.toInt();
      return ComplianceReport.fromJson(json,
          track: tracks != null && index != null && index < tracks.length
              ? tracks[index]
              : null);
    }).toList();

/// Мои по имени, мои анонимные по ключам с телефона и, офицеру, очередь.
Future<ComplianceList> fetchCompliance() async {
  final body = await _request('GET', '/api/compliance');
  final tracks = await _tracks();
  final anonymous = tracks.isEmpty
      ? const <ComplianceReport>[]
      : _items(
          (await _request(
              'POST', '/api/compliance/track', {'tracks': tracks}))['items'],
          tracks: tracks);
  return ComplianceList(
    officer: body['officer'] == true,
    mine: [...anonymous, ..._items(body['mine'])]
      ..sort((a, b) => b.id.compareTo(a.id)),
    queue: _items(body['queue']),
  );
}

Future<ComplianceResult> _post(String path, Map<String, Object?> body,
    {String? track}) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const ComplianceResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      final newTrack =
          parsed['track'] is String ? parsed['track'] as String : null;
      if (newTrack != null) await _saveTrack(newTrack);
      return ComplianceResult(
          item: ComplianceReport.fromJson(
              Map<String, dynamic>.from(parsed['item']),
              track: newTrack ?? track));
    }
    final error = parsed['error'];
    return ComplianceResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return ComplianceResult(problem: problemOf(e));
  }
}

Future<ComplianceResult> sendComplianceReport(
        {required String kind, required String text, bool anonymous = false}) =>
    _post('/api/compliance',
        {'kind': kind, 'text': text, 'anonymous': anonymous});

/// message — автору и офицеру; take и close — офицеру.
Future<ComplianceResult> complianceAction(ComplianceReport item, String action,
        {String text = ''}) =>
    _post(
        '/api/compliance/${item.id}',
        {
          'action': action,
          if (text.isNotEmpty) 'text': text,
          if (item.track != null) 'track': item.track,
        },
        track: item.track);
