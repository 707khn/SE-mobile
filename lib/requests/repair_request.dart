import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItEvent, ItPerson;

/// Что сломалось. По этому выбору сервер и решает, какой службе уйдёт
/// заявка: станок и электрика — службе главного инженера, остальное —
/// хозотделу.
const repairCategories = <String>[
  'equipment',
  'electric',
  'building',
  'plumbing',
  'furniture',
  'vehicle',
  'other',
];

/// Где отметка «стоит» что-то значит: из-за поломки встаёт работа.
const repairCanStop = {'equipment', 'electric', 'vehicle'};

/// Где спрашивать, какой именно станок или машина.
const repairAsksEquipment = {'equipment', 'vehicle'};

const repairOpenStatuses = {'new', 'in_progress'};

class RepairRequest {
  const RepairRequest({
    required this.id,
    required this.category,
    required this.place,
    required this.description,
    required this.status,
    this.service = 'facility',
    this.equipment = '',
    this.phone = '',
    this.stopped = false,
    this.downtimeHours,
    this.author,
    this.assignee,
    this.resolution = '',
    this.createdAt,
    this.updatedAt,
    this.closedAt,
    this.photoCount = 0,
    this.photos = const [],
    this.events = const [],
    this.canAct = false,
  });

  final int id;
  final String category;

  /// engineer или facility — кому заявка сейчас адресована.
  final String service;
  final String place;
  final String equipment;
  final String description;
  final String status;
  final String phone;
  final bool stopped;

  /// Сколько стояло (или стоит до сих пор), в часах. Только у «стоит».
  final double? downtimeHours;
  final ItPerson? author;
  final ItPerson? assignee;
  final String resolution;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? closedAt;
  final int photoCount;
  final List<int> photos;
  final List<ItEvent> events;

  /// Смотрящий — из той службы, которой адресована заявка: ему кнопки
  /// «Взять» и «Выполнено». Решает сервер.
  final bool canAct;

  bool get isOpen => repairOpenStatuses.contains(status);

  bool get canReopen =>
      status == 'done' &&
      closedAt != null &&
      DateTime.now().difference(closedAt!) <= const Duration(days: 14);

  factory RepairRequest.fromJson(Map<String, dynamic> json) {
    final photos = json['photos'];
    final events = json['events'];
    return RepairRequest(
      id: (json['id'] as num?)?.toInt() ?? 0,
      category: '${json['category'] ?? 'other'}',
      service: '${json['service'] ?? 'facility'}',
      place: '${json['place'] ?? ''}',
      equipment: '${json['equipment'] ?? ''}',
      description: '${json['description'] ?? ''}',
      status: '${json['status'] ?? 'new'}',
      phone: '${json['phone'] ?? ''}',
      stopped: json['stopped'] == true,
      downtimeHours: (json['downtime_hours'] as num?)?.toDouble(),
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
      canAct: json['can_act'] == true,
    );
  }
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

/// «Пресс КД2128: 3 раза, стоял 14 ч» — что ломается чаще всего.
class RepairTop {
  const RepairTop(
      {required this.equipment, required this.count, this.downtimeHours = 0});

  final String equipment;
  final int count;
  final double downtimeHours;
}

class RepairRequestList {
  const RepairRequestList({
    required this.items,
    this.staff = false,
    this.photosAllowed = true,
    this.openNew = 0,
    this.openInProgress = 0,
    this.openStopped = 0,
    this.top = const [],
  });

  final List<RepairRequest> items;

  /// Человек из службы главного инженера или хозотдела — ему видна очередь.
  final bool staff;

  /// Фото можно отключить на сервере: снимать на территории можно не везде.
  final bool photosAllowed;
  final int openNew;
  final int openInProgress;
  final int openStopped;
  final List<RepairTop> top;

  factory RepairRequestList.fromJson(Map<String, dynamic> json) {
    final open = json['open'];
    int count(String key) =>
        open is Map ? (open[key] as num?)?.toInt() ?? 0 : 0;
    final top = json['top_equipment'];
    return RepairRequestList(
      items: ((json['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => RepairRequest.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      staff: json['staff'] == true,
      photosAllowed: json['photos_allowed'] != false,
      openNew: count('new'),
      openInProgress: count('in_progress'),
      openStopped: count('stopped'),
      top: top is List
          ? top
              .whereType<Map>()
              .map((e) => RepairTop(
                    equipment: '${e['equipment'] ?? ''}',
                    count: (e['count'] as num?)?.toInt() ?? 0,
                    downtimeHours:
                        (e['downtime_hours'] as num?)?.toDouble() ?? 0,
                  ))
              .toList()
          : const [],
    );
  }
}

class RepairResult {
  const RepairResult({this.item, this.error, this.problem});

  final RepairRequest? item;
  final String? error;
  final LoadProblem? problem;

  bool get ok => item != null;
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

Future<RepairRequestList> fetchRepairRequests({bool queue = false}) async {
  try {
    final response = await http
        .get(_uri('/api/repair-requests${queue ? '?scope=queue' : ''}'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    return RepairRequestList.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

Future<RepairRequest> fetchRepairRequest(int id) async {
  try {
    final response = await http
        .get(_uri('/api/repair-requests/$id'), headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      throw const LoadFailure(LoadProblem.denied);
    }
    if (response.statusCode != 200) {
      throw LoadFailure(problemForStatus(response.statusCode));
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return RepairRequest.fromJson(body['item'] as Map<String, dynamic>);
  } on LoadFailure {
    rethrow;
  } catch (e) {
    throw LoadFailure(problemOf(e), problemDetail(e));
  }
}

RepairResult _result(http.Response response) {
  Map<String, dynamic> body = const {};
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) body = decoded;
  } catch (_) {
    // Не JSON — ответил не наш сервер.
  }
  if ((response.statusCode == 200 || response.statusCode == 201) &&
      body['item'] is Map) {
    return RepairResult(
        item: RepairRequest.fromJson(Map<String, dynamic>.from(body['item'])));
  }
  if (response.statusCode == 413) {
    return const RepairResult(error: 'photo_too_large');
  }
  final error = body['error'];
  return RepairResult(
    error: error is String ? error : null,
    problem: problemForStatus(response.statusCode),
  );
}

/// Новая заявка, фото — в том же запросе.
Future<RepairResult> createRepairRequest({
  required String category,
  required String place,
  required String description,
  String equipment = '',
  String phone = '',
  bool stopped = false,
  List<Uint8List> photos = const [],
}) async {
  try {
    final request =
        http.MultipartRequest('POST', _uri('/api/repair-requests'));
    final headers = await authHeaders();
    headers.remove('Content-Type');
    request.headers.addAll(headers);
    request.fields.addAll({
      'category': category,
      'place': place,
      'description': description,
      if (equipment.isNotEmpty) 'equipment': equipment,
      if (phone.isNotEmpty) 'phone': phone,
      if (stopped) 'stopped': '1',
    });
    for (var i = 0; i < photos.length; i++) {
      request.files.add(http.MultipartFile.fromBytes('photo', photos[i],
          filename: 'photo_${i + 1}.jpg'));
    }
    final streamed =
        await request.send().timeout(const Duration(seconds: 90));
    final response = await http.Response.fromStream(streamed);
    if (await handledUnauthorized(response)) {
      return const RepairResult(problem: LoadProblem.denied);
    }
    return _result(response);
  } catch (e) {
    return RepairResult(problem: problemOf(e));
  }
}

/// take, done, reject, forward, cancel, reopen, comment.
Future<RepairResult> repairRequestAction(int id, String action,
    {String comment = ''}) async {
  try {
    final response = await http
        .post(_uri('/api/repair-requests/$id'),
            headers: await authHeaders(),
            body: jsonEncode({
              'action': action,
              if (comment.isNotEmpty) 'comment': comment,
            }))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const RepairResult(problem: LoadProblem.denied);
    }
    return _result(response);
  } catch (e) {
    return RepairResult(problem: problemOf(e));
  }
}

String repairPhotoUrl(int requestId, int photoId) =>
    '${AppValues.baseUrl}/api/repair-requests/$requestId/photos/$photoId';

