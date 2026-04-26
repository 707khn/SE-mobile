import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> generateTable(List<List<String>> data, BuildContext context) async {
  try {
    final directory = await getExternalStorageDirectories();
    if (directory == null || directory.isEmpty) {
      _showError(context, 'Нет доступа к хранилищу');
      return;
    }
    final path = directory[0].path;
    List<List<dynamic>> rows = [];
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? name = prefs.getString("fullName");
    rows.add(['Дата', 'Время', 'Событие', 'Дверь']);
    for (var entry in data) {
      rows.add(entry);
    }
    var csv = const ListToCsvConverter().convert(rows);
    String tempDir = Directory.systemTemp.path;
    String csvFilePath = '$tempDir/$name.csv';
    String savePath = '$path/saved_report.csv';
    await File(csvFilePath).writeAsString(csv);
    await File(savePath).writeAsString(csv);
    HapticFeedback.lightImpact();
    Share.shareFiles([csvFilePath], text: 'Отправка файла');
  } catch (e) {
    _showError(context, 'Ошибка экспорта CSV: $e');
  }
}

Future<void> generateTableEmp(List<List<List<String>>> data, BuildContext context) async {
  try {
    final directory = await getExternalStorageDirectories();
    if (directory == null || directory.isEmpty) {
      _showError(context, 'Нет доступа к хранилищу');
      return;
    }
    final path = directory[0].path;
    List<List<dynamic>> rows = [];
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? names = prefs.getStringList("emp_snames");

    for (var i = 0; i < data.length; i++) {
      String? name = names?[i];
      rows.add(['$name', '', '', '']);
      rows.add(['Дата', 'Время', 'Событие', 'Дверь']);
      for (var entry in data[i]) {
        rows.add(entry);
      }
      rows.add(['', '', '', '']);
    }

    var csv = const ListToCsvConverter().convert(rows);
    String tempDir = Directory.systemTemp.path;
    String csvFilePath = '$tempDir/report.csv';
    String savePath = '$path/saved_report.csv';
    await File(csvFilePath).writeAsString(csv);
    await File(savePath).writeAsString(csv);
    HapticFeedback.lightImpact();
    Share.shareFiles([csvFilePath], text: 'Отправка файла');
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
