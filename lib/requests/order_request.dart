import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'purchase_request.dart' show isoDay;

const orderKinds = ['order', 'policy', 'instruction'];

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

DateTime? _day(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

/// Приказ, положение или инструкция под отметку «Ознакомлен».
class OrderDoc {
  const OrderDoc({
    required this.id,
    required this.title,
    this.kind = 'order',
    this.number = '',
    this.docDate,
    this.link = '',
    this.departments = const [],
    this.dueDate,
    this.publishedAt,
    this.ackedAt,
    this.withdrawn = false,
    this.total,
    this.acked,
    this.text = '',
    this.addressed = true,
    this.canReport = false,
    this.canRemind = false,
    this.canWithdraw = false,
  });

  final int id;
  final String kind;
  final String number;
  final DateTime? docDate;
  final String title;
  final String link;

  /// Пусто — всё предприятие.
  final List<String> departments;
  final DateTime? dueDate;
  final DateTime? publishedAt;
  final DateTime? ackedAt;
  final bool withdrawn;

  /// Счётчики — только у издающего.
  final int? total;
  final int? acked;

  /// Текст, адресат ли я и кнопки — только в карточке приказа.
  final String text;
  final bool addressed;
  final bool canReport;
  final bool canRemind;
  final bool canWithdraw;

  bool get isAcked => ackedAt != null;

  /// Срок прошёл, а отметки нет.
  bool overdue(DateTime today) =>
      !isAcked &&
      dueDate != null &&
      dueDate!.isBefore(DateTime(today.year, today.month, today.day));

  factory OrderDoc.fromJson(Map<String, dynamic> json) {
    final departments = json['departments'];
    return OrderDoc(
      id: (json['id'] as num?)?.toInt() ?? 0,
      kind: '${json['kind'] ?? 'order'}',
      number: '${json['number'] ?? ''}',
      docDate: _day(json['doc_date']),
      title: '${json['title'] ?? ''}',
      link: '${json['link'] ?? ''}',
      departments: departments is List
          ? departments.whereType<String>().toList()
          : const [],
      dueDate: _day(json['due_date']),
      publishedAt: _time(json['published_at']),
      ackedAt: _time(json['acked_at']),
      withdrawn: json['withdrawn'] == true,
      total: (json['total'] as num?)?.toInt(),
      acked: (json['acked'] as num?)?.toInt(),
      text: '${json['text'] ?? ''}',
      addressed: json['addressed'] != false,
      canReport: json['can_report'] == true,
      canRemind: json['can_remind'] == true,
      canWithdraw: json['can_withdraw'] == true,
    );
  }
}

class OrderList {
  const OrderList(
      {required this.items,
      this.publisher = false,
      this.manager = false,
      this.pending = 0});

  final List<OrderDoc> items;
  final bool publisher;
  final bool manager;
  final int pending;

  factory OrderList.fromJson(Map<String, dynamic> json) => OrderList(
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => OrderDoc.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        publisher: json['publisher'] == true,
        manager: json['manager'] == true,
        pending: (json['pending'] as num?)?.toInt() ?? 0,
      );
}

class OrderReader {
  const OrderReader(
      {required this.id,
      required this.name,
      this.department = '',
      this.ackedAt});

  final String id;
  final String name;
  final String department;
  final DateTime? ackedAt;

  factory OrderReader.fromJson(Map<String, dynamic> json) => OrderReader(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        department: '${json['department'] ?? ''}',
        ackedAt: _time(json['acked_at']),
      );
}

class OrderReport {
  const OrderReport({required this.people, this.total = 0, this.acked = 0});

  final List<OrderReader> people;
  final int total;
  final int acked;

  factory OrderReport.fromJson(Map<String, dynamic> json) => OrderReport(
        people: ((json['people'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => OrderReader.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        total: (json['total'] as num?)?.toInt() ?? 0,
        acked: (json['acked'] as num?)?.toInt() ?? 0,
      );
}

class OrderDepartment {
  const OrderDepartment({required this.name, this.count = 0});

  final String name;
  final int count;
}

class OrderResult {
  const OrderResult({this.item, this.reminded, this.error, this.problem});

  final OrderDoc? item;

  /// Скольким ушло напоминание.
  final int? reminded;
  final String? error;
  final LoadProblem? problem;

  bool get ok => item != null || reminded != null;
}

Uri _uri(String path) => Uri.parse('${AppValues.baseUrl}$path');

Future<Map<String, dynamic>> _get(String path) async {
  try {
    final response = await http
        .get(_uri(path), headers: await authHeaders())
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

Future<OrderList> fetchOrders({bool published = false}) async =>
    OrderList.fromJson(
        await _get('/api/orders${published ? '?scope=published' : ''}'));

Future<OrderDoc> fetchOrder(int id) async {
  final body = await _get('/api/orders/$id');
  return OrderDoc.fromJson(body['item'] as Map<String, dynamic>);
}

Future<OrderReport> fetchOrderReport(int id) async =>
    OrderReport.fromJson(await _get('/api/orders/$id/report'));

Future<List<OrderDepartment>> fetchOrderDepartments() async {
  final body = await _get('/api/orders/departments');
  return ((body['departments'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => OrderDepartment(
          name: '${e['name'] ?? ''}',
          count: (e['count'] as num?)?.toInt() ?? 0))
      .where((d) => d.name.isNotEmpty)
      .toList();
}

Future<OrderResult> _post(String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const OrderResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if (response.statusCode == 200 || response.statusCode == 201) {
      if (parsed['item'] is Map) {
        return OrderResult(
            item: OrderDoc.fromJson(Map<String, dynamic>.from(parsed['item'])));
      }
      if (parsed['reminded'] is num) {
        return OrderResult(reminded: (parsed['reminded'] as num).toInt());
      }
    }
    final error = parsed['error'];
    return OrderResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return OrderResult(problem: problemOf(e));
  }
}

Future<OrderResult> publishOrder({
  required String kind,
  required String title,
  required String text,
  String number = '',
  DateTime? docDate,
  String link = '',
  List<String> departments = const [],
  DateTime? dueDate,
}) =>
    _post('/api/orders', {
      'kind': kind,
      'title': title,
      'text': text,
      if (number.isNotEmpty) 'number': number,
      if (docDate != null) 'doc_date': isoDay(docDate),
      if (link.isNotEmpty) 'link': link,
      'departments': departments,
      if (dueDate != null) 'due_date': isoDay(dueDate),
    });

/// ack, remind или withdraw.
Future<OrderResult> orderAction(int id, String action) =>
    _post('/api/orders/$id', {'action': action});
