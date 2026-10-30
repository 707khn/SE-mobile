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
