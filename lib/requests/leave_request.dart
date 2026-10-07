import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';
import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/offline_cache.dart';

class LeaveBalance {
  final String type;
  final int totalDays;
  final int usedDays;
  final int remainingDays;

  LeaveBalance({
    required this.type,
    required this.totalDays,
    required this.usedDays,
    required this.remainingDays,
  });
}

class LeaveRecord {
  final String type;
  final String startDate;
  final String endDate;
  final int days;
  final String status;

  LeaveRecord({
    required this.type,
    required this.startDate,
    required this.endDate,
    required this.days,
    required this.status,
  });
}

class LeaveData {
  final String employee;
  final List<LeaveBalance> balances;
  final List<LeaveRecord> history;

  /// Когда данные получены с сервера. У свежих пусто, у показанных без
  /// связи — время последнего удачного запроса.
  final DateTime? cachedAt;

  LeaveData({
    required this.employee,
    required this.balances,
    required this.history,
    this.cachedAt,
  });

  /// Из ответа /leaves (или его сохранённой копии).
  static LeaveData fromJson(Map<String, dynamic> body) {
    final data = body['leaves'] as Map;
    final stamp = body[OfflineCache.stampKey];
    return LeaveData(
      employee: '${data['employee'] ?? ''}',
      balances: [
        for (final b in (data['balances'] as List? ?? const []))
          LeaveBalance(
            type: '${b['type'] ?? ''}',
            totalDays: (b['total_days'] as num?)?.toInt() ?? 0,
            usedDays: (b['used_days'] as num?)?.toInt() ?? 0,
            remainingDays: (b['remaining_days'] as num?)?.toInt() ?? 0,
          ),
      ],
      history: [
        for (final h in (data['history'] as List? ?? const []))
          LeaveRecord(
            type: '${h['type'] ?? ''}',
            startDate: '${h['start_date'] ?? ''}',
            endDate: '${h['end_date'] ?? ''}',
            days: (h['days'] as num?)?.toInt() ?? 0,
            status: '${h['status'] ?? ''}',
          ),
      ],
      cachedAt: stamp is String ? DateTime.tryParse(stamp) : null,
    );
  }
}

Future<String?> _resolveEmployeeId() async {
  final id = await SecureStorageHelper.instance.getEmployeeId();
  if (id != null && id.isNotEmpty) return id;
  return employeeIdFromServer();
}

/// [employeeId] overrides the signed-in user — used by the admin panel.
///
/// null — сервер ответил, что такого сотрудника нет. Не дозвонились до
/// сервера — данные, полученные в прошлый раз, а если их нет — [LoadFailure]
/// с причиной: раньше на всё был один ответ «данные не найдены», и человек
/// без интернета думал, что у него пропал отпуск.
Future<LeaveData?> getLeaves(BuildContext context, {String? employeeId}) async {
  final own = employeeId == null || employeeId.isEmpty;
  final login = own ? await _resolveEmployeeId() : employeeId;
  if (login == null || login.isEmpty) return null;
  // Копия — только своя: отпуск сотрудника, открытый руководителем, на его
  // телефоне оставлять незачем.
  final cacheKey = own ? 'leaves_$login' : null;

  final http.Response response;
  try {
    response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/leaves'),
          headers: await authHeaders(),
          body: jsonEncode({'key_suffix': login}),
        )
        .timeout(const Duration(seconds: 15));
  } catch (e) {
    return _cachedOr(cacheKey, problemOf(e));
  }

  if (await handledUnauthorized(response)) return null;
  if (response.statusCode != 200) {
    return _cachedOr(cacheKey, problemForStatus(response.statusCode));
  }
  try {
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['message'] != 'Success') return null;
    final data = LeaveData.fromJson(body);
    if (cacheKey != null) await OfflineCache.save(cacheKey, body);
    return data;
  } catch (e) {
    return _cachedOr(cacheKey, LoadProblem.server);
  }
}

Future<LeaveData> _cachedOr(String? key, LoadProblem problem) async {
  final saved = key == null ? null : await OfflineCache.read(key);
  if (saved != null) {
    try {
      return LeaveData.fromJson(saved);
    } catch (_) {
      // Сохранённое не читается — как будто его нет.
    }
  }
  throw LoadFailure(problem);
}
