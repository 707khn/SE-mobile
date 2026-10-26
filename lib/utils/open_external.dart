import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import 'desktop.dart';

/// Открывает ссылку, номер или адрес в другом приложении, а если не вышло —
/// говорит об этом.
///
/// Прежде неудача проходила молча: на телефоне без почтовой программы
/// нажатие на адрес в справочнике не делало ничего, и человек нажимал снова
/// и снова. Ссылку на обновление это касается так же — без неё новую версию
/// не поставить.
///
/// Номер телефона на компьютере звонить некуда: Windows отдаёт tel: в
/// Teams или Skype, а чаще не отдаёт никуда. Там номер копируется — набрать
/// его на рабочем аппарате или вставить в мессенджер.
Future<void> openExternal(BuildContext context, String target) async {
  if (isDesktop && target.startsWith('tel:')) {
    final number = target.substring(4);
    await Clipboard.setData(ClipboardData(text: number));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('phone_copied'.trParams({'number': number}))));
    }
    return;
  }
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
