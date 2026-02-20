import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> generateTable(List<List<String>> data) async {
  final directory = await getExternalStorageDirectories();
  final path = directory?[0].path;
  List<List<dynamic>> rows = [];
  String? name = "";
  SharedPreferences prefs = await SharedPreferences.getInstance();
  /*if (prefs.containsKey("emp_sname")){
    name = prefs.getString("emp_sname");
  } else {*/
    name = prefs.getString("fullName");
  /*}*/
  rows.add(['Дата', 'Время', 'Событие', 'Дверь']);
  for (var entry in data) {
    rows.add(entry);
  }
  var csv = ListToCsvConverter().convert(rows);
  String tempDir = Directory.systemTemp.path;
  String csvFilePath = '$tempDir/$name.csv';
  String savePath = '$path/saved_report.csv';
  File file = File(csvFilePath);
  file.writeAsStringSync(csv);
  file = File(savePath);
  file.writeAsStringSync(csv);

  Share.shareFiles([file.path], text: 'Отправка файла');
}

Future<void> generateTableEmp(List<List<List<String>>> data) async {
  final directory = await getExternalStorageDirectories();
  final path = directory?[0].path;
  List<List<dynamic>> rows = [];
  String? name = "";
  SharedPreferences prefs = await SharedPreferences.getInstance();

  List<String>? names = prefs.getStringList("emp_snames");

  for (var i = 0; i < data.length; i ++){
    name = names?[i];
    rows.add(['$name', '', '', '']);
    rows.add(['Дата', 'Время', 'Событие', 'Дверь']);
    for (var entry in data[i]) {
      rows.add(entry);
    }
    rows.add(['', '', '', '']);
  }

  var csv = ListToCsvConverter().convert(rows);
  String tempDir = Directory.systemTemp.path;
  String csvFilePath = '$tempDir/report.csv';
  String savePath = '$path/saved_report.csv';
  File file = File(csvFilePath);
  file.writeAsStringSync(csv);
  file = File(savePath);
  file.writeAsStringSync(csv);
  Share.shareFiles([file.path], text: 'Отправка файла');
}


