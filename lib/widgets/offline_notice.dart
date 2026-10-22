import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../utils/app_theme.dart';
import '../utils/connection_watch.dart';
import '../utils/lang.dart';

/// Полоска «показано сохранённое» над экраном, работающим без связи.
///
/// Нужна не для красоты: без неё человек примет вчерашнее меню за сегодняшнее,
/// а старый листок — за свежий. Дата получения снимает вопрос.
///
/// Пока полоска на экране, приложение ждёт связи и, когда сервер снова
/// ответил, само вызывает [onRetry] — человеку не нужно помнить, что экран
/// надо потянуть вниз.
class OfflineNotice extends StatefulWidget {
  const OfflineNotice({Key? key, required this.at, this.onRetry})
      : super(key: key);

  /// Когда данные были получены. Пусто — полоска не показывается.
  final DateTime? at;

  /// Загрузить заново: по кнопке на полоске и само, когда связь вернулась.
  final VoidCallback? onRetry;

  @override
  State<OfflineNotice> createState() => _OfflineNoticeState();
}

class _OfflineNoticeState extends State<OfflineNotice> {
  StreamSubscription<void>? _sub;

  bool get _waiting => widget.at != null && widget.onRetry != null;

  @override
  void initState() {
    super.initState();
    if (_waiting) _startWaiting();
  }

  @override
  void didUpdateWidget(OfflineNotice old) {
    super.didUpdateWidget(old);
    final was = old.at != null && old.onRetry != null;
    if (was && !_waiting) _stopWaiting();
    if (!was && _waiting) _startWaiting();
  }

  @override
  void dispose() {
    _stopWaiting();
    super.dispose();
  }

  void _startWaiting() {
    ConnectionWatch.instance.hold();
    _sub = ConnectionWatch.instance.restored.listen((_) {
      if (mounted && _waiting) widget.onRetry!();
    });
  }

  void _stopWaiting() {
    if (_sub == null) return;
    _sub!.cancel();
    _sub = null;
    ConnectionWatch.instance.release();
  }

  @override
  Widget build(BuildContext context) {
    final moment = widget.at;
    if (moment == null) return const SizedBox.shrink();

    final now = DateTime.now();
    final sameDay = now.year == moment.year &&
        now.month == moment.month &&
        now.day == moment.day;
    final stamp = sameDay
        ? DateFormat('HH:mm').format(moment)
        : DateFormat('d MMMM, HH:mm', Lang.dates).format(moment);

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
          if (widget.onRetry != null)
            IconButton(
              icon: Icon(Icons.refresh, size: 18, color: context.mutedColor),
              tooltip: 'offline_retry'.tr,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: widget.onRetry,
            ),
        ],
      ),
    );
  }
}
