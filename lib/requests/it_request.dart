import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

/// Что сломалось. Порядок — как на экране новой заявки.
const itCategories = <String>[
  'printer',
  'computer',
  'network',
  'phone',
  'software',
  'account',
  'other',
];

const itOpenStatuses = {'new', 'in_progress'};

/// Человек в заявке: автор, исполнитель или тот, кто оставил запись.
class ItPerson {
  const ItPerson({required this.id, required this.name, this.department = ''});

  final String id;
  final String name;
  final String department;

  static ItPerson? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return ItPerson(
      id: '${raw['id'] ?? ''}',
      name: '${raw['name'] ?? ''}',
      department: '${raw['department'] ?? ''}',
    );
  }

  /// «Николаев Даниил Олегович» → «Николаев Д. О.»: в строке статуса
  /// полное ФИО не помещается.
  String get short {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return name;
    final initials =
        parts.skip(1).where((p) => p.isNotEmpty).map((p) => '${p[0]}.');
    return '${parts.first} ${initials.join(' ')}';
  }
}

/// Строка истории заявки.
class ItEvent {
  const ItEvent(
      {required this.action, required this.at, this.actor, this.comment = ''});

  final String action;
  final DateTime? at;
  final ItPerson? actor;
  final String comment;

  factory ItEvent.fromJson(Map<String, dynamic> json) => ItEvent(
        action: '${json['action'] ?? ''}',
        at: _time(json['at']),
        actor: ItPerson.fromJson(json['actor']),
        comment: '${json['comment'] ?? ''}',
      );
}

class ItRequest {
  const ItRequest({
    required this.id,
    required this.category,
    required this.room,
    required this.description,
    required this.status,
    this.phone = '',
    this.author,
    this.assignee,
    this.resolution = '',
    this.createdAt,
    this.updatedAt,
    this.closedAt,
    this.photoCount = 0,
    this.photos = const [],
    this.events = const [],
  });

  final int id;
  final String category;
  final String room;
  final String description;
  final String status;
  final String phone;
  final ItPerson? author;
  final ItPerson? assignee;
  final String resolution;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? closedAt;
  final int photoCount;

  /// Номера снимков — только в подробном ответе.
  final List<int> photos;
  final List<ItEvent> events;

  bool get isOpen => itOpenStatuses.contains(status);

  /// «Не помогло» можно сказать две недели после «выполнено» — так же
  /// решает сервер.
  bool get canReopen =>
      status == 'done' &&
      closedAt != null &&
      DateTime.now().difference(closedAt!) <= const Duration(days: 14);

  factory ItRequest.fromJson(Map<String, dynamic> json) {
    final photos = json['photos'];
    final events = json['events'];
    return ItRequest(
      id: (json['id'] as num?)?.toInt() ?? 0,
      category: '${json['category'] ?? 'other'}',
      room: '${json['room'] ?? ''}',
      description: '${json['description'] ?? ''}',
      status: '${json['status'] ?? 'new'}',
      phone: '${json['phone'] ?? ''}',
      author: ItPerson.fromJson(json['author']),
      assignee: ItPerson.fromJson(json['assignee']),
      resolution: '${json['resolution'] ?? ''}',
      createdAt: _time(json['created_at']),
      updatedAt: _time(json['updated_at']),
      closedAt: _time(json['closed_at']),
      photoCount: (json['photo_count'] as num?)?.toInt() ??
          (photos is List ? photos.length : 0),
      photos: photos is List
          ? photos.whereType<num>().map((e) => e.toInt()).toList()
          : const [],
      events: events is List
          ? events
              .whereType<Map>()
              .map((e) => ItEvent.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
    );
  }
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

/// Список заявок: свои или, для ОИТиС, очередь.
class ItRequestList {
  const ItRequestList({
    required this.items,
    this.itStaff = false,
    this.openNew = 0,
    this.openInProgress = 0,
  });

  final List<ItRequest> items;

  /// Сервер сам говорит, видит ли человек очередь: кто в ОИТиС, решает он.
  final bool itStaff;
  final int openNew;
  final int openInProgress;

  factory ItRequestList.fromJson(Map<String, dynamic> json) {
    final open = json['open'];
    return ItRequestList(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => ItRequest.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      itStaff: json['it_staff'] == true,
      openNew: open is Map ? (open['new'] as num?)?.toInt() ?? 0 : 0,
      openInProgress:
          open is Map ? (open['in_progress'] as num?)?.toInt() ?? 0 : 0,
    );
  }
}

/// Чем закончилась отправка или действие: заявка или код ошибки сервера.
class ItResult {
  const ItResult({this.item, this.error, this.problem});

  final ItRequest? item;

  /// Код отказа сервера: room_required, too_many_open, closed…
  final String? error;
  final LoadProblem? problem;

  bool get ok => item != null;
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

Future<ItRequestList> fetchItRequests({bool queue = false}) async {
  try {
    final response = await http
        .get(_uri('/api/it-requests${queue ? '?scope=queue' : ''}'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    return ItRequestList.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

Future<ItRequest> fetchItRequest(int id) async {
  try {
    final response = await http
        .get(_uri('/api/it-requests/$id'), headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return ItRequest.fromJson(body['item'] as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

ItResult _result(http.Response response) {
  Map<String, dynamic> body = const {};
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) body = decoded;
  } catch (_) {
    // Не JSON — значит, ответил не наш сервер (nginx, гостевой Wi-Fi).
  }
  if ((response.statusCode == 200 || response.statusCode == 201) &&
      body['item'] is Map) {
    return ItResult(
        item: ItRequest.fromJson(Map<String, dynamic>.from(body['item'])));
  }
  if (response.statusCode == 413) return const ItResult(error: 'photo_too_large');
  final error = body['error'];
  return ItResult(
    error: error is String ? error : null,
    problem: problemForStatus(response.statusCode),
  );
}

/// Новая заявка. Фото уходят в том же запросе: заявка без своих снимков
/// не должна появиться в очереди даже на минуту.
Future<ItResult> createItRequest({
  required String category,
  required String room,
  required String description,
  String phone = '',
  List<Uint8List> photos = const [],
}) async {
  try {
    final request = http.MultipartRequest('POST', _uri('/api/it-requests'));
    final headers = await authHeaders();
    // Границу частей ставит сам MultipartRequest; JSON здесь не нужен.
    headers.remove('Content-Type');
    request.headers.addAll(headers);
    request.fields.addAll({
      'category': category,
      'room': room,
      'description': description,
      if (phone.isNotEmpty) 'phone': phone,
    });
    for (var i = 0; i < photos.length; i++) {
      request.files.add(http.MultipartFile.fromBytes('photo', photos[i],
          filename: 'photo_${i + 1}.jpg'));
    }
    // Три фото по мобильному интернету — не двадцать секунд.
    final streamed =
        await request.send().timeout(const Duration(seconds: 90));
    final response = await http.Response.fromStream(streamed);
    if (await handledUnauthorized(response)) {
      return const ItResult(problem: LoadProblem.denied);
    }
    return _result(response);
  } catch (e) {
    return ItResult(problem: problemOf(e));
  }
}

/// take, done, reject, cancel, reopen, comment.
Future<ItResult> itRequestAction(int id, String action,
    {String comment = ''}) async {
  try {
    final response = await http
        .post(_uri('/api/it-requests/$id'),
            headers: await authHeaders(),
            body: jsonEncode({
              'action': action,
              if (comment.isNotEmpty) 'comment': comment,
            }))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const ItResult(problem: LoadProblem.denied);
    }
    return _result(response);
  } catch (e) {
    return ItResult(problem: problemOf(e));
  }
}

String itPhotoUrl(int requestId, int photoId) =>
    '${AppValues.baseUrl}/api/it-requests/$requestId/photos/$photoId';
