import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'export_file.dart';
import 'sheet_name.dart';

Future<void> generateExcel(List<List<String>> data, BuildContext context) async {
  try {
    final directory = await getExternalStorageDirectories();
    if (directory == null || directory.isEmpty) {
      _showError(context, 'url_error'.tr);
      return;
    }
    final path = directory[0].path;
    String? name = "";
    SharedPreferences prefs = await SharedPreferences.getInstance();
    name = prefs.getString("fullName");
    var excel = Excel.createExcel();
    // Имя листа — не ФИО как есть: у двенадцати человек из справочника оно
    // длиннее тридцати одного знака, и такой файл Excel открывать
    // отказывается.
    var sheet = excel[excelSheetName(name ?? '', <String>{})];
    sheet.appendRow(['$name']);
    sheet.appendRow(['col_date'.tr, 'col_time'.tr, 'col_event'.tr, 'col_door'.tr]);
    for (var entry in data) {
      sheet.appendRow(entry);
    }
    excel.delete('Sheet1');
    String tempDir = Directory.systemTemp.path;
    // Имя файла — с датой: прежде каждая выгрузка называлась одинаково и
    // затирала предыдущую, а их и сравнивают между собой.
    final fileName = exportFileName(name, 'xlsx');
    String excelFilePath = '$tempDir/$fileName';
    String savePath = '$path/$fileName';
    var excelBytes = excel.save();
    if (excelBytes == null) {
      _showError(context, 'Не удалось создать файл');
      return;
    }
    await File(excelFilePath).writeAsBytes(excelBytes);
    await File(savePath).writeAsBytes(excelBytes);
    HapticFeedback.lightImpact();
    Share.shareFiles([excelFilePath], text: 'send_report_tooltip'.tr);
  } catch (e) {
    _showError(context, 'Ошибка экспорта Excel: $e');
  }
}

Future<void> generateExcelEmp(List<List<List<String>>> data, BuildContext context) async {
  try {
    final directory = await getExternalStorageDirectories();
    if (directory == null || directory.isEmpty) {
      _showError(context, 'url_error'.tr);
      return;
    }
    final path = directory[0].path;
    SharedPreferences prefs = await SharedPreferences.getInstance();
    List<String>? names = prefs.getStringList("emp_snames");
    var excel = Excel.createExcel();

    var sheetMain = excel['Все данные'];

    // Список имён и список отчётов ведутся порознь, и один из них может
    // оказаться короче: тогда names?[i] бросал RangeError, а человек видел
    // «Ошибка экспорта Excel: RangeError» вместо файла.
    String nameAt(int i) =>
        (names != null && i < names.length) ? names[i] : 'Лист ${i + 1}';

    for (var i = 0; i < data.length; i++) {
      sheetMain.appendRow([nameAt(i)]);
      sheetMain.appendRow(['col_date'.tr, 'col_time'.tr, 'col_event'.tr, 'col_door'.tr]);
      for (var entry in data[i]) {
        sheetMain.appendRow(entry);
      }
      sheetMain.appendRow([""]);
      sheetMain.appendRow([""]);
    }

    final taken = <String>{'Все данные'};
    for (var i = 0; i < data.length; i++) {
      final rowName = nameAt(i);
      var sheet = excel[excelSheetName(rowName, taken)];
      sheet.appendRow([rowName]);
      // Заголовки те же, что и в общем листе: здесь они были прибиты
      // по-русски, и казахскую книгу это делало наполовину русской.
      sheet.appendRow(['col_date'.tr, 'col_time'.tr, 'col_event'.tr, 'col_door'.tr]);
      for (var entry in data[i]) {
        sheet.appendRow(entry);
      }
    }
    excel.delete('Sheet1');
    String tempDir = Directory.systemTemp.path;
    final fileName = exportFileName('report', 'xlsx');
    String excelFilePath = '$tempDir/$fileName';
    String savePath = '$path/$fileName';
    var excelBytes = excel.save();
    if (excelBytes == null) {
      _showError(context, 'Не удалось создать файл');
      return;
    }
    await File(excelFilePath).writeAsBytes(excelBytes);
    await File(savePath).writeAsBytes(excelBytes);
    HapticFeedback.lightImpact();
    Share.shareFiles([excelFilePath], text: 'send_report_tooltip'.tr);
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
