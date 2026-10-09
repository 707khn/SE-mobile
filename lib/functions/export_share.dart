import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';

import 'export_file.dart';

/// Записывает выгрузку к прежним и открывает «Поделиться».
///
/// Отправляется сам записанный файл. Прежде рядом писалась ещё и копия во
/// временную папку, и обе не убирались никогда.
Future<void> saveAndShare(BuildContext context, String? who, String extension,
    List<int> bytes) async {
  try {
    final file =
        await saveExport(await exportDirectory(), who, extension, bytes);
    HapticFeedback.lightImpact();
    await Share.shareXFiles([XFile(file.path)], text: 'send_report_tooltip'.tr);
  } catch (_) {
    if (context.mounted) showExportMessage(context, 'export_failed'.tr);
  }
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
        ResultType.noAppToOpen => 'export_no_app'.tr,
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
