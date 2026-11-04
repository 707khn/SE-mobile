import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/desktop.dart';
import 'export_file.dart';

/// Записывает выгрузку к прежним и открывает «Поделиться».
///
/// Отправляется сам записанный файл. Прежде рядом писалась ещё и копия во
/// временную папку, и обе не убирались никогда.
Future<void> saveAndShare(BuildContext context, String? who, String extension,
    List<int> bytes) async {
  if (kIsWeb) {
    await shareBytesOnWeb(context, exportFileName(who, extension), bytes,
        text: 'send_report_tooltip'.tr);
    return;
  }
  try {
    final file =
        await saveExport(await exportDirectory(), who, extension, bytes);
    if (isDesktop) {
      if (context.mounted) showSavedFile(context, file);
      return;
    }
    HapticFeedback.lightImpact();
    await Share.shareXFiles([XFile(file.path)], text: 'send_report_tooltip'.tr);
  } catch (_) {
    if (context.mounted) showExportMessage(context, 'export_failed'.tr);
  }
}

/// Хранятся ли выгрузки на устройстве — есть ли что открыть кнопкой
/// «Просмотреть последний файл». В браузере папки для них нет.
bool get keepsExports => !kIsWeb;

/// Выгрузка в браузере: файл собирается в памяти и сразу уходит в
/// «Поделиться» — на iPhone это то же системное окно, что у приложения:
/// почта, Telegram, «Сохранить в Файлы». Где «Поделиться» с файлами нет
/// (браузер на компьютере), файл просто скачивается.
Future<void> shareBytesOnWeb(
    BuildContext context, String name, List<int> bytes,
    {String? text}) async {
  try {
    await Share.shareXFiles([
      XFile.fromData(Uint8List.fromList(bytes),
          name: name, mimeType: exportMimeType(name)),
    ], text: text, fileNameOverrides: [name]);
  } catch (_) {
    if (context.mounted) showExportMessage(context, 'export_failed'.tr);
  }
}

/// Тип файла по расширению — без него Safari не знает, чем открыть
/// выгрузку, и предлагает сохранить её как «документ».
String exportMimeType(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.xlsx')) {
    return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
  }
  if (lower.endsWith('.csv')) return 'text/csv';
  return 'application/octet-stream';
}

/// Кнопка выгрузки: на телефоне — «Поделиться», на компьютере — «Сохранить».
IconData get exportIcon => isDesktop ? Icons.download : Icons.share;

/// Надпись выгрузки по ключу телефонной: на компьютере файл не отправляют,
/// а сохраняют — и подпись с «Отправить» обещала бы то, чего не будет.
String exportLabel(String phoneKey) =>
    (isDesktop ? _desktopLabels[phoneKey] ?? phoneKey : phoneKey).tr;

const Map<String, String> _desktopLabels = {
  'send report exc': 'save report exc',
  'send report csv': 'save report csv',
  'send_report_tooltip': 'save_report_tooltip',
};

/// На компьютере «Поделиться» не с кем: мессенджеров, которые подхватили бы
/// файл, там нет. Файл уже лежит в «Загрузках» — говорим, где именно, и
/// даём открыть папку, чтобы перетащить его в письмо или в Telegram.
void showSavedFile(BuildContext context, File file) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    duration: const Duration(seconds: 8),
    // С кнопкой Flutter держит сообщение, пока его не закроют, — а оно
    // заслоняет низ экрана и переезжает со вкладки на вкладку.
    persist: false,
    content: Text('export_saved_to'.trParams({'path': file.path})),
    action: SnackBarAction(
      label: 'open_folder'.tr,
      onPressed: () => launchUrl(Uri.directory(file.parent.path)),
    ),
  ));
}

/// Отправить текст: на телефоне — «Поделиться», на компьютере — в буфер
/// обмена, откуда его вставят в письмо или в чат.
Future<void> shareText(BuildContext context, String text) async {
  if (!isDesktop) {
    await Share.share(text);
    return;
  }
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showExportMessage(context, 'copied'.tr);
}

/// Открывает последнюю выгрузку этого вида — или говорит, почему не вышло.
///
/// Раньше кнопка не говорила ничего: нет файла, нет программы для Excel на
/// телефоне — человек нажимал, и ничего не происходило.
Future<void> openLatestExport(
    BuildContext context, String? who, String extension) async {
  String? problem;
  try {
    final file = latestExport(await exportDirectory(), who, extension);
    if (file == null) {
      problem = 'export_none_yet'.tr;
    } else {
      final result = await OpenFile.open(file.path);
      problem = switch (result.type) {
        ResultType.done => null,
        ResultType.noAppToOpen =>
          isDesktop ? 'export_no_app_pc'.tr : 'export_no_app'.tr,
        _ => 'url_error'.tr,
      };
    }
  } catch (_) {
    problem = 'url_error'.tr;
  }
  if (problem != null && context.mounted) showExportMessage(context, problem);
}

void showExportMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
