import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'export_file.dart';

Future<void> generateTable(List<List<String>> data, BuildContext context) async {
  try {
    final directory = await getExternalStorageDirectories();
    if (directory == null || directory.isEmpty) {
      _showError(context, 'url_error'.tr);
      return;
    }
    final path = directory[0].path;
    List<List<dynamic>> rows = [];
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? name = prefs.getString("fullName");
    rows.add(['col_date'.tr, 'col_time'.tr, 'col_event'.tr, 'col_door'.tr]);
    for (var entry in data) {
      rows.add(entry);
    }
    // Точка с запятой, а не запятая: Excel с русской и казахской
    // раскладкой считает разделителем списка именно её, и файл с запятыми
    // открывается одним столбцом на всю строку.
    var csv = utf8Bom +
        const ListToCsvConverter(fieldDelimiter: ';').convert(rows);
    String tempDir = Directory.systemTemp.path;
    final fileName = exportFileName(name, 'csv');
    String csvFilePath = '$tempDir/$fileName';
    String savePath = '$path/$fileName';
    await File(csvFilePath).writeAsString(csv);
    await File(savePath).writeAsString(csv);
    HapticFeedback.lightImpact();
    Share.shareFiles([csvFilePath], text: 'send_report_tooltip'.tr);
  } catch (e) {
    _showError(context, 'Ошибка экспорта CSV: $e');
  }
}

Future<void> generateTableEmp(List<List<List<String>>> data, BuildContext context) async {
  try {
    final directory = await getExternalStorageDirectories();
    if (directory == null || directory.isEmpty) {
      _showError(context, 'url_error'.tr);
      return;
    }
    final path = directory[0].path;
    List<List<dynamic>> rows = [];
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? names = prefs.getStringList("emp_snames");

    // Список имён и список отчётов ведутся порознь: names?[i] бросал
    // RangeError, если один из них оказывался короче, и человек видел
    // «Ошибка экспорта CSV: RangeError» вместо файла.
    String nameAt(int i) =>
        (names != null && i < names.length) ? names[i] : 'Сотрудник ${i + 1}';

    for (var i = 0; i < data.length; i++) {
      rows.add([nameAt(i), '', '', '']);
      rows.add(['col_date'.tr, 'col_time'.tr, 'col_event'.tr, 'col_door'.tr]);
      for (var entry in data[i]) {
        rows.add(entry);
      }
      rows.add(['', '', '', '']);
    }

    var csv = utf8Bom +
        const ListToCsvConverter(fieldDelimiter: ';').convert(rows);
    String tempDir = Directory.systemTemp.path;
    final fileName = exportFileName('report', 'csv');
    String csvFilePath = '$tempDir/$fileName';
    String savePath = '$path/$fileName';
    await File(csvFilePath).writeAsString(csv);
    await File(savePath).writeAsString(csv);
    HapticFeedback.lightImpact();
    Share.shareFiles([csvFilePath], text: 'send_report_tooltip'.tr);
  } catch (e) {
    _showError(context, 'Ошибка экспорта CSV: $e');
  }
}

void _showError(BuildContext context, String message) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
