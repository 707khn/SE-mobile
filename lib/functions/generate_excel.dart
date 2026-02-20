import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void generateExcel(List<List<String>> data) async {
  final directory = await getExternalStorageDirectories();
  final path = directory?[0].path;
  String? name = "";
  SharedPreferences prefs = await SharedPreferences.getInstance();
  /*if (prefs.containsKey("emp_sname")){
    name = prefs.getString("emp_sname");
  } else {*/
    name = prefs.getString("fullName");
  /*}*/
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
  await File(excelFilePath).writeAsBytes(excelBytes!);
  await File(savePath).writeAsBytes(excelBytes);
  Share.shareFiles([excelFilePath], text: 'Отправка файла');
}

void generateExcelEmp(List<List<List<String>>> data) async {
  final directory = await getExternalStorageDirectories();
  final path = directory?[0].path;
  String? name = "";
  SharedPreferences prefs = await SharedPreferences.getInstance();
  List<String>? names = prefs.getStringList("emp_snames");
  var excel = Excel.createExcel();

  var sheet_main = excel['Все данные'];

  for (var i = 0; i < data.length; i ++){
    sheet_main.appendRow([names?[i]]);
    sheet_main.appendRow(['Дата', 'Время', 'Событие', 'Дверь']);
    for (var entry in data[i]) {
      sheet_main.appendRow(entry);
    }
    sheet_main.appendRow([""]);
    sheet_main.appendRow([""]);
  }


  for (var i = 0; i < data.length; i ++){
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
  await File(excelFilePath).writeAsBytes(excelBytes!);
  await File(savePath).writeAsBytes(excelBytes);
  Share.shareFiles([excelFilePath], text: 'Отправка файла');
}
