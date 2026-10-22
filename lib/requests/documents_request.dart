import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../utils/api.dart';
import '../utils/load_problem.dart';
import '../utils/offline_cache.dart';
import '../utils/variables.dart';

/// Документ предприятия: приказ, положение, график, образец заявления.
class CompanyDocument {
  CompanyDocument({
    required this.id,
    required this.category,
    required this.categoryName,
    required this.title,
    required this.number,
    required this.date,
    required this.filename,
    required this.size,
    required this.requiresAck,
    required this.ackedAt,
    required this.createdAt,
  });

  factory CompanyDocument.fromJson(Map<String, dynamic> json) =>
      CompanyDocument(
        id: (json['id'] as int?) ?? 0,
        category: (json['category'] as String?) ?? 'other',
        categoryName: (json['category_name'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        number: (json['number'] as String?) ?? '',
        date: DateTime.tryParse((json['date'] as String?) ?? ''),
        filename: (json['filename'] as String?) ?? '',
        size: (json['size'] as int?) ?? 0,
        requiresAck: json['requires_ack'] == true,
        ackedAt: json['acked'] == true
            ? (DateTime.tryParse((json['acked_at'] as String?) ?? '') ??
                DateTime.now())
            : null,
        createdAt: DateTime.tryParse((json['created_at'] as String?) ?? ''),
      );

  final int id;
  final String category;
  final String categoryName;
  final String title;
  final String number;
  final DateTime? date;
  final String filename;
  final int size;
  final bool requiresAck;

  /// Когда человек отметил «Ознакомлен»; `null` — ещё не отмечал.
  final DateTime? ackedAt;
  final DateTime? createdAt;

  /// Ждёт от человека отметки.
  bool get awaitingAck => requiresAck && ackedAt == null;

  /// Расширение файла — для значка: PDF, Word, Excel, картинка.
  String get extension {
    final dot = filename.lastIndexOf('.');
    return dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  }
}

/// Раздел и его документы — в порядке, в котором сервер называет разделы.
class DocumentSection {
  DocumentSection(this.key, this.name, this.documents);

  final String key;
  final String name;
  final List<CompanyDocument> documents;
}

/// Раскладывает документы по разделам. Пустые разделы не показываем:
/// заголовок «Образцы заявлений» над пустотой только сбивает.
List<DocumentSection> groupDocuments(
    List<CompanyDocument> docs, List<Map<String, dynamic>> categories) {
  final sections = <DocumentSection>[];
  final known = <String>{};
  for (final c in categories) {
    final key = (c['key'] as String?) ?? '';
    known.add(key);
    final inIt = docs.where((d) => d.category == key).toList();
    if (inIt.isNotEmpty) {
      sections.add(DocumentSection(key, (c['name'] as String?) ?? key, inIt));
    }
  }
  // Раздел, которого эта сборка не знает, — в конец, а не в никуда.
  final rest = docs.where((d) => !known.contains(d.category)).toList();
  if (rest.isNotEmpty) {
    sections.add(DocumentSection('other', rest.first.categoryName, rest));
  }
  return sections;
}

/// «1,2 МБ», «340 КБ».
String documentSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',')} МБ';
  }
  return '${(bytes / 1024).ceil()} КБ';
}

/// Сколько документов ждут отметки «Ознакомлен». Меню показывает число
/// рядом с разделом, не дожидаясь, пока его откроют.
final ValueNotifier<int> documentsPending = ValueNotifier<int>(0);

/// Список документов. Без связи — сохранённый в прошлый раз.
Future<Map<String, dynamic>> getDocuments() async {
  try {
    final response = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/documents'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return {'message': 'Failure', 'items': []};
    }
    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      documentsPending.value = (body['pending'] as int?) ?? 0;
      await OfflineCache.save('documents', body);
      return body;
    }
    return await _cached(problemForStatus(response.statusCode));
  } catch (e) {
    return await _cached(problemOf(e));
  }
}

Future<Map<String, dynamic>> _cached(LoadProblem problem) async {
  final saved = await OfflineCache.read('documents');
  if (saved != null) return saved;
  return {'message': 'Failure', 'items': [], problemKey: problem.name};
}

/// Обновить число в меню. Молча: это подсказка, а не экран.
Future<void> refreshDocumentsPending() async {
  try {
    await getDocuments();
  } catch (_) {}
}

/// Содержимое файла; `null` — не скачалось.
Future<List<int>?> downloadDocument(int id) async {
  try {
    final response = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/documents/$id/file'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 60));
    if (await handledUnauthorized(response)) return null;
    if (response.statusCode != 200) return null;
    return response.bodyBytes;
  } catch (_) {
    return null;
  }
}

/// «Ознакомлен». Возвращает документ с отметкой или `null`.
Future<CompanyDocument?> acknowledgeDocument(int id) async {
  try {
    final response = await http
        .post(Uri.parse('${AppValues.baseUrl}/api/documents/$id/ack'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) return null;
    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final item = body['item'];
    if (item is! Map<String, dynamic>) return null;
    if (documentsPending.value > 0) documentsPending.value--;
    return CompanyDocument.fromJson(item);
  } catch (_) {
    return null;
  }
}

/// Кто ознакомился и кто ещё нет — для составителя.
Future<Map<String, dynamic>> getDocumentAcks(int id) async {
  try {
    final response = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/admin/documents/$id/acks'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) {
      return {'message': 'Failure'};
    }
    if (response.statusCode == 200) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    return {
      'message': 'Failure',
      problemKey: problemForStatus(response.statusCode).name,
    };
  } catch (e) {
    return {'message': 'Failure', problemKey: problemOf(e).name};
  }
}

Future<bool> deleteDocument(int id) async {
  try {
    final response = await http
        .delete(Uri.parse('${AppValues.baseUrl}/api/admin/documents/$id'),
            headers: await authHeaders())
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) return false;
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// Включить или снять отметку «нужно ознакомиться».
Future<bool> setDocumentRequiresAck(int id, bool value) async {
  try {
    final response = await http
        .post(Uri.parse('${AppValues.baseUrl}/api/admin/documents/$id'),
            headers: await authHeaders(),
            body: jsonEncode({'requires_ack': value}))
        .timeout(const Duration(seconds: 20));
    if (await handledUnauthorized(response)) return false;
    return response.statusCode == 200;
  } catch (_) {
    return false;
  }
}
