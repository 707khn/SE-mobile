import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../utils/app_theme.dart';

/// Полоска «показано сохранённое» над экраном, работающим без связи.
///
/// Нужна не для красоты: без неё человек примет вчерашнее меню за сегодняшнее,
/// а старый листок — за свежий. Дата получения снимает вопрос.
class OfflineNotice extends StatelessWidget {
  const OfflineNotice({Key? key, required this.at}) : super(key: key);

  /// Когда данные были получены. Пусто — полоска не показывается.
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final moment = at;
    if (moment == null) return const SizedBox.shrink();

    final now = DateTime.now();
    final sameDay = now.year == moment.year &&
        now.month == moment.month &&
        now.day == moment.day;
    final stamp = sameDay
        ? DateFormat('HH:mm').format(moment)
        : DateFormat('d MMMM, HH:mm', 'ru').format(moment);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: context.mutedColor.withOpacity(0.12),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 16, color: context.mutedColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${'offline_saved'.tr} $stamp',
              style: TextStyle(fontSize: 12, color: context.mutedColor),
            ),
          ),
        ],
      ),
    );
  }
}
