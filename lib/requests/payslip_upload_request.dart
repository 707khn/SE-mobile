import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/variables.dart';

/// Кого из листков нет среди сотрудников приложения.
class PayslipUploadPerson {
  const PayslipUploadPerson({required this.id, required this.name});

  final String id;
  final String name;
}

/// Что сервер нашёл в файле — до публикации (`dryRun`) и после неё.
class PayslipUploadSummary {
  const PayslipUploadSummary({
    required this.periods,
    required this.count,
    required this.added,
    required this.replaced,
    required this.unknown,
    required this.published,
  });

  final List<String> periods;
  final int count;

  /// Листков, которых за этот месяц у человека ещё не было.
  final int added;

  /// Листков, которые заменят уже загруженные — перевыгрузка с поправками.
  final int replaced;
  final List<PayslipUploadPerson> unknown;

  /// Записаны и разосланы, а не только проверены.
  final bool published;

  factory PayslipUploadSummary.fromJson(Map<String, dynamic> json) {
    int number(Object? v) => v is num ? v.toInt() : 0;
    final unknown = json['unknown'];
    return PayslipUploadSummary(
      periods: [
        for (final p in (json['periods'] is List ? json['periods'] : []))
          '$p'
      ],
      count: number(json['count']),
      added: number(json['new']),
      replaced: number(json['replaced']),
      unknown: [
        for (final u in (unknown is List ? unknown : []))
          if (u is Map)
            PayslipUploadPerson(
                id: '${u['employee_id'] ?? ''}',
                name: '${u['full_name'] ?? ''}'),
      ],
      published: json['dry_run'] != true,
    );
  }
}

class PayslipUploadResult {
  const PayslipUploadResult({this.summary, this.message = '', this.problem});

  final PayslipUploadSummary? summary;

  /// Что не так с самим файлом — словами сервера («нет табельного номера…»).
  final String message;
  final LoadProblem? problem;
}

/// Отправить файл с листками. `dryRun` — только проверить, ничего не писать.
///
/// Файл на всё предприятие весит десятки мегабайт, а сервер разбирает и
/// записывает пятьсот листков — минута здесь нормальна.
Future<PayslipUploadResult> uploadPayslips(
  String fileName,
  Uint8List bytes, {
  required bool dryRun,
}) async {
  try {
    final request = http.MultipartRequest(
        'POST', Uri.parse('${AppValues.baseUrl}/api/payslips/import-excel'));
    final headers = await authHeaders();
    headers.remove('Content-Type');
    request.headers.addAll(headers);
    if (dryRun) request.fields['dry_run'] = '1';
    request.files
        .add(http.MultipartFile.fromBytes('file', bytes, filename: fileName));
    final streamed =
        await request.send().timeout(const Duration(minutes: 3));
    final response = await http.Response.fromStream(streamed);
    if (await handledUnauthorized(response)) {
      return const PayslipUploadResult(problem: LoadProblem.denied);
    }
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) body = decoded;
    } on FormatException {
      body = null;
    }
    if (response.statusCode == 200 && body != null) {
      return PayslipUploadResult(summary: PayslipUploadSummary.fromJson(body));
    }
    if (response.statusCode == 413) {
      return const PayslipUploadResult(message: 'psu_too_big');
    }
    final message = body?['message'];
    // 400 и 422 — ответ про сам файл: его и показываем.
    if ((response.statusCode == 400 || response.statusCode == 422) &&
        message is String &&
        message.isNotEmpty) {
      return PayslipUploadResult(message: message);
    }
    return PayslipUploadResult(
        problem: problemForStatus(response.statusCode));
  } catch (e) {
    return PayslipUploadResult(problem: problemOf(e));
  }
}

/// Загруженный месяц в разделе «Расчётные листы».
class PayslipPeriodInfo {
  const PayslipPeriodInfo({
    required this.year,
    required this.month,
    required this.title,
    required this.count,
    this.uploadedAt,
    this.uploadedBy = '',
    this.file = '',
    this.uploadedCount = 0,
  });

  final int year;
  final int month;
  final String title;
  final int count;

  /// Последняя загрузка за месяц. null — листки легли до журнала загрузок.
  final DateTime? uploadedAt;
  final String uploadedBy;
  final String file;
  final int uploadedCount;

  static PayslipPeriodInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int number(Object? v) => v is num ? v.toInt() : 0;
    final up = raw['uploaded'];
    return PayslipPeriodInfo(
      year: number(raw['year']),
      month: number(raw['month']),
      title: '${raw['title'] ?? ''}',
      count: number(raw['count']),
      uploadedAt: up is Map ? DateTime.tryParse('${up['at']}')?.toLocal() : null,
      uploadedBy: up is Map ? '${up['by'] ?? ''}' : '',
      file: up is Map ? '${up['file'] ?? ''}' : '',
      uploadedCount: up is Map ? number(up['count']) : 0,
    );
  }
}

/// Строка листка в списке месяца.
class PayslipRow {
  const PayslipRow({
    required this.employeeId,
    required this.fullName,
    this.department = '',
    this.netPay = 0,
    this.accruals = 0,
    this.deductions = 0,
  });

  final String employeeId;
  final String fullName;
  final String department;
  final double netPay;
  final double accruals;
  final double deductions;

  static PayslipRow? fromJson(Object? raw) {
    if (raw is! Map) return null;
    double money(Object? v) => v is num ? v.toDouble() : 0;
    return PayslipRow(
      employeeId: '${raw['employee_id'] ?? ''}',
      fullName: '${raw['full_name'] ?? ''}',
      department: '${raw['department'] ?? ''}',
      netPay: money(raw['net_pay']),
      accruals: money(raw['total_accruals']),
      deductions: money(raw['total_deductions']),
    );
  }
}

Uri _admin(String path) =>
    Uri.parse('${AppValues.baseUrl}/api/payslips/periods$path');

Future<Map<String, dynamic>> _getJson(Uri uri) async {
  final response = await http
      .get(uri, headers: await authHeaders())
      .timeout(const Duration(seconds: 30));
  if (await handledUnauthorized(response)) {
    throw const LoadFailure(LoadProblem.denied);
  }
  if (response.statusCode != 200) {
    throw LoadFailure(problemForStatus(response.statusCode));
  }
  final body = jsonDecode(utf8.decode(response.bodyBytes));
  if (body is! Map<String, dynamic>) {
    throw const LoadFailure(LoadProblem.server);
  }
  return body;
}

/// Загруженные месяцы, свежие сверху. Бросает LoadFailure.
Future<List<PayslipPeriodInfo>> fetchPayslipAdminPeriods() async {
  final body = await _getJson(_admin(''));
  final items = body['items'];
  return [
    for (final raw in (items is List ? items : const []))
      if (PayslipPeriodInfo.fromJson(raw) case final p?) p
  ];
}

/// Листки месяца по алфавиту. Бросает LoadFailure.
Future<List<PayslipRow>> fetchPayslipMonth(int year, int month) async {
  final body = await _getJson(_admin('/$year/$month'));
  final items = body['items'];
  return [
    for (final raw in (items is List ? items : const []))
      if (PayslipRow.fromJson(raw) case final r?) r
  ];
}

/// Удалить месяц целиком или листок одного сотрудника. null — удалено,
/// иначе причина.
Future<LoadProblem?> deletePayslips(int year, int month,
    {String? employeeId}) async {
  try {
    final response = await http
        .delete(_admin('/$year/$month${employeeId == null ? '' : '/$employeeId'}'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 60));
    if (await handledUnauthorized(response)) return LoadProblem.denied;
    if (response.statusCode == 200 || response.statusCode == 404) return null;
    return problemForStatus(response.statusCode);
  } catch (e) {
    return problemOf(e);
  }
}
