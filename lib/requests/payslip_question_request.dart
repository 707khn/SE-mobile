import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';
import 'it_request.dart' show ItPerson;

class PayslipQuestionMessage {
  const PayslipQuestionMessage(
      {required this.text,
      this.kind = 'message',
      this.at,
      this.author,
      this.fromPayroll = false});

  final String text;

  /// message или closed — отметка «вопрос решён».
  final String kind;
  final DateTime? at;
  final ItPerson? author;
  final bool fromPayroll;

  factory PayslipQuestionMessage.fromJson(Map<String, dynamic> json) =>
      PayslipQuestionMessage(
        text: '${json['text'] ?? ''}',
        kind: '${json['kind'] ?? 'message'}',
        at: _time(json['at']),
        author: ItPerson.fromJson(json['author']),
        fromPayroll: json['from_payroll'] == true,
      );
}

class PayslipQuestion {
  const PayslipQuestion({
    required this.id,
    required this.year,
    required this.month,
    required this.status,
    this.line = '',
    this.preview = '',
    this.author,
    this.assignee,
    this.updatedAt,
    this.messages = const [],
    this.isAuthor = false,
    this.canAnswer = false,
  });

  final int id;
  final int year;
  final int month;

  /// open — ждёт бухгалтера, answered — ответили, closed — решено.
  final String status;
  final String line;
  final String preview;
  final ItPerson? author;
  final ItPerson? assignee;
  final DateTime? updatedAt;
  final List<PayslipQuestionMessage> messages;
  final bool isAuthor;
  final bool canAnswer;

  DateTime get period => DateTime(year, month);

  factory PayslipQuestion.fromJson(Map<String, dynamic> json) {
    final messages = json['messages'];
    return PayslipQuestion(
      id: (json['id'] as num?)?.toInt() ?? 0,
      year: (json['year'] as num?)?.toInt() ?? 2000,
      month: (json['month'] as num?)?.toInt() ?? 1,
      status: '${json['status'] ?? 'open'}',
      line: '${json['line'] ?? ''}',
      preview: '${json['preview'] ?? ''}',
      author: ItPerson.fromJson(json['author']),
      assignee: ItPerson.fromJson(json['assignee']),
      updatedAt: _time(json['updated_at']),
      messages: messages is List
          ? messages
              .whereType<Map>()
              .map((e) =>
                  PayslipQuestionMessage.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      isAuthor: json['is_author'] == true,
      canAnswer: json['can_answer'] == true,
    );
  }
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;

class PayslipQuestionList {
  const PayslipQuestionList(
      {required this.items, this.staff = false, this.open = 0});

  final List<PayslipQuestion> items;

  /// Расчётная группа: у неё есть очередь.
  final bool staff;
  final int open;

  factory PayslipQuestionList.fromJson(Map<String, dynamic> json) =>
      PayslipQuestionList(
        items: ((json['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => PayslipQuestion.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        staff: json['staff'] == true,
        open: (json['open'] as num?)?.toInt() ?? 0,
      );
}

class PayslipQuestionResult {
  const PayslipQuestionResult({this.item, this.error, this.problem});

  final PayslipQuestion? item;
  final String? error;
  final LoadProblem? problem;

  bool get ok => item != null;
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

Future<PayslipQuestionList> fetchPayslipQuestions({bool queue = false}) async =>
    PayslipQuestionList.fromJson(
        await _get('/api/payslip-questions${queue ? '?scope=queue' : ''}'));

Future<PayslipQuestion> fetchPayslipQuestion(int id) async {
  final body = await _get('/api/payslip-questions/$id');
  return PayslipQuestion.fromJson(body['item'] as Map<String, dynamic>);
}

Future<PayslipQuestionResult> _post(
    String path, Map<String, Object?> body) async {
  try {
    final response = await http
        .post(_uri(path), headers: await authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return const PayslipQuestionResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic> parsed = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) parsed = decoded;
    } catch (_) {}
    if ((response.statusCode == 200 || response.statusCode == 201) &&
        parsed['item'] is Map) {
      return PayslipQuestionResult(
          item: PayslipQuestion.fromJson(
              Map<String, dynamic>.from(parsed['item'])));
    }
    final error = parsed['error'];
    return PayslipQuestionResult(
        error: error is String ? error : null,
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return PayslipQuestionResult(problem: problemOf(e));
  }
}

Future<PayslipQuestionResult> askPayslipQuestion(
        {required int year,
        required int month,
        required String text,
        String line = ''}) =>
    _post('/api/payslip-questions', {
      'year': year,
      'month': month,
      'text': text,
      if (line.isNotEmpty) 'line': line,
    });

/// reply или close.
Future<PayslipQuestionResult> payslipQuestionAction(int id, String action,
        {String text = ''}) =>
    _post('/api/payslip-questions/$id', {
      'action': action,
      if (text.isNotEmpty) 'text': text,
    });
