import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> generateExcel(List<List<String>> data, BuildContext context) async {
  try {
    final directory = await getExternalStorageDirectories();
    if (directory == null || directory.isEmpty) {
      _showError(context, 'Нет доступа к хранилищу');
      return;
    }
    final path = directory[0].path;
    String? name = "";
    SharedPreferences prefs = await SharedPreferences.getInstance();
    name = prefs.getString("fullName");
    var excel = Excel.createExcel();
    var sheet = excel['$name'];
    sheet.appendRow(['$name']);
    sheet.appendRow(['Дата', 'Время', 'Событие', 'Дверь']);
    for (var entry in data) {
      sheet.appendRow(entry);
    }
    excel.delete('Sheet1');
    String tempDir = Directory.systemTemp.path;
    String excelFilePath = '$tempDir/$name.xlsx';
    String savePath = '$path/saved_report.xlsx';
    var excelBytes = excel.save();
    if (excelBytes == null) {
      _showError(context, 'Не удалось создать файл');
      return;
    }
    await File(excelFilePath).writeAsBytes(excelBytes);
    await File(savePath).writeAsBytes(excelBytes);
    Share.shareFiles([excelFilePath], text: 'Отправка файла');
  } catch (e) {
    _showError(context, 'Ошибка экспорта Excel: $e');
  }
}

Future<void> generateExcelEmp(List<List<List<String>>> data, BuildContext context) async {
  try {
    final directory = await getExternalStorageDirectories();
    if (directory == null || directory.isEmpty) {
      _showError(context, 'Нет доступа к хранилищу');
      return;
    }
    final path = directory[0].path;
    String? name = "";
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? names = prefs.getStringList("emp_snames");
    var excel = Excel.createExcel();

    var sheetMain = excel['Все данные'];

    for (var i = 0; i < data.length; i++) {
      sheetMain.appendRow([names?[i]]);
      sheetMain.appendRow(['Дата', 'Время', 'Событие', 'Дверь']);
      for (var entry in data[i]) {
        sheetMain.appendRow(entry);
      }
      sheetMain.appendRow([""]);
      sheetMain.appendRow([""]);
    }

    for (var i = 0; i < data.length; i++) {
      name = names?[i];
      var sheet = excel['$name'];
      sheet.appendRow(['$name']);
      sheet.appendRow(['Дата', 'Время', 'Событие', 'Дверь']);
      for (var entry in data[i]) {
        sheet.appendRow(entry);
      }
    }
    excel.delete('Sheet1');
    String tempDir = Directory.systemTemp.path;
    String excelFilePath = '$tempDir/report.xlsx';
    String savePath = '$path/saved_report.xlsx';
    var excelBytes = excel.save();
    if (excelBytes == null) {
      _showError(context, 'Не удалось создать файл');
      return;
    }
    await File(excelFilePath).writeAsBytes(excelBytes);
    await File(savePath).writeAsBytes(excelBytes);
    Share.shareFiles([excelFilePath], text: 'Отправка файла');
  } catch (e) {
    _showError(context, 'Ошибка экспорта Excel: $e');
  }
}

void _showError(BuildContext context, String message) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
