import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../screens/notifications_screen.dart';
import '../utils/notice_badge.dart';

/// Колокольчик в шапке главного экрана: число — сколько нового.
///
/// Без него в приложение заходили, только когда что-то было нужно, и
/// новости, меню и листок за месяц никто не замечал: пуш через Firebase
/// не настроен, а другого способа сказать «у вас новое» не было.
class NotificationBell extends StatelessWidget {
  const NotificationBell({Key? key, required this.job}) : super(key: key);

  final String job;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: NoticeBadge.count,
      builder: (context, count, _) => IconButton(
        tooltip: 'notices'.tr,
        icon: Badge(
          isLabelVisible: count > 0,
          label: Text(count > 99 ? '99+' : '$count'),
          child:
              Icon(count > 0 ? Icons.notifications : Icons.notifications_none),
        ),
        onPressed: () async {
          await Get.to(() => NotificationsScreen(job: job));
          NoticeBadge.refresh();
        },
      ),
    );
  }
}
