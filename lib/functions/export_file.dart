/// Как называется выгруженный файл.
///
/// Раньше и отчёт по себе, и отчёт по отделу сохранялись под одним именем —
/// `saved_report.xlsx`. Вторая выгрузка затирала первую, а сравнивают их как
/// раз между собой: «посмотри, что было в июле и что в августе».
String exportFileName(String? who, String stampedExtension) {
  final safe = fileSafe(who);
  return '${safe}_${exportStamp()}.$stampedExtension';
}

/// Отметка времени для имени файла.
String exportStamp() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}';
}

/// Имя, пригодное для файловой системы.
///
/// Заменяем только заведомо опасное — разделители пути, кавычки, пробелы, —
/// а буквы оставляем: имя файла на казахском или русском читается человеком,
/// и превращать его в набор подчёркиваний незачем.
String fileSafe(String? raw) {
  final name = (raw ?? '')
      .trim()
      .replaceAll(RegExp(r'[\\/:*?"<>|\s]'), '_')
      .replaceAll(RegExp(r'_+'), '_');
  // Обрезаем подчёркивания по краям: «Отдел/цех: "первый" *» иначе даёт
  // «Отдел_цех___первый___», а имя из одних разделителей — сплошные
  // подчёркивания вместо имени.
  final cleaned = name.replaceAll(RegExp(r'^_+|_+$'), '');
  return cleaned.isEmpty ? 'report' : cleaned;
}

/// Метка в начале файла, по которой Excel понимает, что текст в UTF-8.
///
/// Без неё Excel на Windows читает файл как windows-1251, и вместо «Дата»
/// человек видит «Ð”Ð°Ñ‚Ð°». Три байта, из-за которых выгрузка выглядит
/// сломанной.
const String utf8Bom = '﻿';
