import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

/// Открывает ссылку, номер или адрес в другом приложении, а если не вышло —
/// говорит об этом.
///
/// Прежде неудача проходила молча: на телефоне без почтовой программы
/// нажатие на адрес в справочнике не делало ничего, и человек нажимал снова
/// и снова. Ссылку на обновление это касается так же — без неё новую версию
/// не поставить.
Future<void> openExternal(BuildContext context, String target) async {
  var opened = false;
  try {
    opened = await launchUrl(Uri.parse(target),
        mode: LaunchMode.externalApplication);
  } catch (_) {
    // Нет программы для такой ссылки или сама ссылка кривая — для человека
    // это одно и то же.
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('url_error'.tr)));
  }
}
