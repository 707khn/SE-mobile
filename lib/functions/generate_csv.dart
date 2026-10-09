import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'export_file.dart';
import 'export_share.dart';

/// Свой отчёт по проходам — или того, чей отчёт открыл администратор.
/// Имя — того, чьи это проходы, а не вошедшего (см. generateExcel).
Future<void> generateTable(
    String? name, List<List<String>> data, BuildContext context) async {
  await saveAndShare(context, name, 'csv', utf8.encode(buildCsv(data)));
}

/// Отчёт по отделу: проходы каждого из [names] — в [data] под тем же номером.
Future<void> generateTableEmp(List<String> names,
    List<List<List<String>>> data, BuildContext context) async {
  final String csv;
  try {
    csv = buildCsvEmp(names, data);
  } catch (_) {
    showExportMessage(context, 'export_failed'.tr);
    return;
  }
  await saveAndShare(context, 'report', 'csv', utf8.encode(csv));
}

String buildCsv(List<List<String>> data) {
  List<List<dynamic>> rows = [];
  rows.add(['col_date'.tr, 'col_time'.tr, 'col_event'.tr, 'col_door'.tr]);
  for (var entry in data) {
    rows.add(entry);
  }
  return _csv(rows);
}

/// Имена и проходы приходят парами — как и в книге Excel (см. buildExcelEmp).
String buildCsvEmp(List<String> names, List<List<List<String>>> data) {
  if (names.length != data.length) {
    throw ArgumentError('${names.length} имён на ${data.length} отчётов');
  }
  List<List<dynamic>> rows = [];
  for (var i = 0; i < data.length; i++) {
    rows.add([names[i], '', '', '']);
    rows.add(['col_date'.tr, 'col_time'.tr, 'col_event'.tr, 'col_door'.tr]);
    for (var entry in data[i]) {
      rows.add(entry);
    }
    rows.add(['', '', '', '']);
  }
  return _csv(rows);
}

// Точка с запятой, а не запятая: Excel с русской и казахской раскладкой
// считает разделителем списка именно её, и файл с запятыми открывается
// одним столбцом на всю строку.
String _csv(List<List<dynamic>> rows) =>
    utf8Bom + const ListToCsvConverter(fieldDelimiter: ';').convert(rows);
