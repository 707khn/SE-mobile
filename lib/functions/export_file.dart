import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../utils/desktop.dart';

/// Как называется выгруженный файл.
///
/// Раньше и отчёт по себе, и отчёт по отделу сохранялись под одним именем —
/// `saved_report.xlsx`. Вторая выгрузка затирала первую, а сравнивают их как
/// раз между собой: «посмотри, что было в июле и что в августе».
String exportFileName(String? who, String stampedExtension, {DateTime? at}) {
  final safe = fileSafe(who);
  return '${safe}_${exportStamp(at: at)}.$stampedExtension';
}

/// Отметка времени для имени файла — с секундами.
///
/// До минуты было мало: начальник выгружает июль, меняет даты и тут же
/// выгружает август — в ту же минуту, под тем же именем, и август молча
/// затирал июль.
String exportStamp({DateTime? at}) {
  final now = at ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
}

/// Сколько выгрузок одного вида держать на телефоне.
///
/// Каждая выгрузка ложится отдельным файлом — их сравнивают между собой, —
/// но прежде они не убирались никогда: у начальника, который выгружает отдел
/// каждую неделю, за год копилась сотня файлов с чужими проходами.
const int keepExports = 10;

/// Где лежат выгрузки.
///
/// На Android — папка приложения в памяти телефона, как и прежде: там уже
/// лежат сделанные выгрузки. На iPhone такой папки нет, и прежний вызов
/// бросал исключение — там это документы приложения.
///
/// На компьютере — «Загрузки\SemEng»: туда человек и пойдёт искать
/// скачанное, и оттуда же перетащит файл в письмо. Своя папка внутри — чтобы
/// уборка при выходе касалась только наших файлов.
Future<Directory> exportDirectory() async {
  if (isDesktop) {
    Directory? base;
    try {
      base = await getDownloadsDirectory();
    } catch (_) {
      // Linux спрашивает папку у xdg-user-dir, а его может и не быть.
    }
    base ??= await getApplicationDocumentsDirectory();
    return Directory('${base.path}${Platform.pathSeparator}SemEng');
  }
  if (Platform.isAndroid) {
    final dirs = await getExternalStorageDirectories();
    if (dirs != null && dirs.isNotEmpty) return dirs.first;
  }
  return getApplicationDocumentsDirectory();
}

/// Записывает выгрузку в [dir] и убирает лишние старые того же вида.
///
/// Вид — это чья выгрузка ([who]) и в каком формате ([extension]): свой отчёт
/// и отчёт по отделу, Excel и CSV считаются порознь.
Future<File> saveExport(
    Directory dir, String? who, String extension, List<int> bytes,
    {DateTime? at}) async {
  await dir.create(recursive: true);
  final file = File('${dir.path}${Platform.pathSeparator}'
      '${exportFileName(who, extension, at: at)}');
  await file.writeAsBytes(bytes, flush: true);
  for (final old in _exports(dir, who, extension).skip(keepExports)) {
    try {
      await old.delete();
    } catch (_) {
      // Не удалилось сейчас — удалится при следующей выгрузке.
    }
  }
  return file;
}

/// Последняя выгрузка этого вида; `null`, если выгрузок не было.
///
/// Кнопки «Просмотреть последний файл» открывали `saved_report.xlsx` — так
/// файл назывался, пока в имени не появились человек и дата. После этого
/// файла с таким именем не стало, и кнопки молча не делали ничего.
File? latestExport(Directory dir, String? who, String extension) {
  final all = _exports(dir, who, extension);
  return all.isEmpty ? null : all.first;
}

/// Стирает все выгрузки — при выходе.
///
/// Выход и так стирает с телефона всё, что принадлежало вошедшему. Файлы с
/// проходами — тоже его, а у начальника в них ещё и проходы всего отдела:
/// телефон, отданный другому, не должен их хранить.
Future<void> clearExports(Directory dir) async {
  if (!await dir.exists()) return;
  // Расчётные листки ложатся сюда только на компьютере: на телефоне они
  // уходят через «Поделиться» из временной папки.
  final ours = RegExp(r'(_\d{4}-\d{2}-\d{2}_\d{4}(\d{2})?|^saved_report'
      r'|^Расчетный листок .*)\.(xlsx|csv)$');
  await for (final entity in dir.list()) {
    if (entity is File && ours.hasMatch(baseName(entity.path))) {
      try {
        await entity.delete();
      } catch (_) {
        // Не удалилось — значит, не удалилось: выход важнее.
      }
    }
  }
}

/// Выгрузки этого вида в [dir], новые первыми.
List<File> _exports(Directory dir, String? who, String extension) {
  if (!dir.existsSync()) return const <File>[];
  final pattern = RegExp('^${RegExp.escape(fileSafe(who))}_'
      '(\\d{4}-\\d{2}-\\d{2}_\\d{4}(?:\\d{2})?)\\.'
      '${RegExp.escape(extension)}\$');
  final found = <(String, File)>[];
  for (final entity in dir.listSync()) {
    if (entity is! File) continue;
    final match = pattern.firstMatch(baseName(entity.path));
    // Отметки прежних выгрузок — без секунд: дополняем нулями, чтобы
    // сравнивать их с новыми знак в знак.
    if (match != null) found.add((match.group(1)!.padRight(17, '0'), entity));
  }
  found.sort((a, b) => b.$1.compareTo(a.$1));
  return [for (final (_, file) in found) file];
}

/// Имя файла без папок.
///
/// Делить путь только по «/» нельзя: на Windows папки разделяет «\», и
/// тогда «имя» оказывалось всем путём целиком — выгрузки не находились ни
/// кнопкой «Просмотреть», ни уборкой при выходе.
String baseName(String path) => path.split(RegExp(r'[/\\]')).last;

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
