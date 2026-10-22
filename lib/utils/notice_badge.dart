import 'package:flutter/foundation.dart';

import '../requests/notifications_request.dart';

/// Число на колокольчике. Одно на всё приложение.
///
/// Колокольчик на главном экране и экран оповещений должны видеть одно и
/// то же: прочитал ленту — и число на главном погасло сразу, а не при
/// следующем запуске.
class NoticeBadge {
  NoticeBadge._();

  static final ValueNotifier<int> count = ValueNotifier<int>(0);

  /// Спросить сервер. Без связи число остаётся прежним.
  static Future<void> refresh() async {
    final fresh = await fetchUnreadCount();
    if (fresh != null) count.value = fresh;
  }

  /// После выхода — ноль: следующий вошедший не должен видеть чужое число.
  static void reset() => count.value = 0;
}
