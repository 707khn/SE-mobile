import 'package:excel/excel.dart';
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:get/get.dart';

import 'export_share.dart';
import 'sheet_name.dart';

/// Свой отчёт по проходам — или того, чей отчёт открыл администратор.
///
/// Имя — того, чьи это проходы. Прежде оно бралось из настроек телефона, то
/// есть было именем вошедшего: администратор выгружал проходы сотрудника, а
/// в файле и на листе стояло его собственное имя.
Future<void> generateExcel(
    String? name, List<List<String>> data, BuildContext context) async {
  final bytes = _built(() => buildExcel(name, data));
  if (bytes == null) {
    showExportMessage(context, 'export_failed'.tr);
    return;
  }
  await saveAndShare(context, name, 'xlsx', bytes);
}

/// Отчёт по отделу: проходы каждого из [names] — в [data] под тем же номером.
Future<void> generateExcelEmp(List<String> names,
    List<List<List<String>>> data, BuildContext context) async {
  final bytes = _built(() => buildExcelEmp(names, data));
  if (bytes == null) {
    showExportMessage(context, 'export_failed'.tr);
    return;
  }
  await saveAndShare(context, 'report', 'xlsx', bytes);
}

List<int>? _built(List<int>? Function() build) {
  try {
    return build();
  } catch (_) {
    return null;
  }
}

List<CellValue?> _row(List<String> cells) =>
    [for (final cell in cells) TextCellValue(cell)];

List<CellValue?> _header() =>
    _row(['col_date'.tr, 'col_time'.tr, 'col_event'.tr, 'col_door'.tr]);

List<int>? buildExcel(String? name, List<List<String>> data) {
  var excel = Excel.createExcel();
  // Имя листа — не ФИО как есть: у двенадцати человек из справочника оно
  // длиннее тридцати одного знака, и такой файл Excel открывать
  // отказывается.
  var sheet = excel[excelSheetName(name ?? '', <String>{})];
  sheet.appendRow(_row([name ?? '']));
  sheet.appendRow(_header());
  for (var entry in data) {
    sheet.appendRow(_row(entry));
  }
  excel.delete('Sheet1');
  return excel.save();
}

/// Книга отчёта по отделу: общий лист и по листу на человека.
///
/// Имена и проходы приходят парами. Прежде имена брались из сохранённого
/// списка, а проходы — из загруженных на экране, и когда списки
/// расходились, проходы одного человека ложились под фамилией другого.
List<int>? buildExcelEmp(List<String> names, List<List<List<String>>> data) {
  if (names.length != data.length) {
    throw ArgumentError('${names.length} имён на ${data.length} отчётов');
  }
  var excel = Excel.createExcel();

  final allSheet = 'export_all_sheet'.tr;
  var sheetMain = excel[allSheet];
  for (var i = 0; i < data.length; i++) {
    sheetMain.appendRow(_row([names[i]]));
    sheetMain.appendRow(_header());
    for (var entry in data[i]) {
      sheetMain.appendRow(_row(entry));
    }
    sheetMain.appendRow(_row(['']));
    sheetMain.appendRow(_row(['']));
  }

  final taken = <String>{allSheet};
  for (var i = 0; i < data.length; i++) {
    var sheet = excel[excelSheetName(names[i], taken)];
    sheet.appendRow(_row([names[i]]));
    // Заголовки те же, что и в общем листе: здесь они были прибиты
    // по-русски, и казахскую книгу это делало наполовину русской.
    sheet.appendRow(_header());
    for (var entry in data[i]) {
      sheet.appendRow(_row(entry));
    }
  }
  excel.delete('Sheet1');
  return excel.save();
}
