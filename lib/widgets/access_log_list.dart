import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../utils/colors.dart';
import '../utils/app_theme.dart';

/// Turnstile events as day-grouped rows.
///
/// These used to be a four-column DataTable pinned to a fixed width inside a
/// horizontal scroller — the app even shipped a "scroll right to see more"
/// hint, which is an admission the layout did not fit a phone. Here the date
/// is a heading instead of a repeated column, freeing the width for time,
/// event and door to sit side by side with nothing off-screen.
class AccessLogList extends StatelessWidget {
  const AccessLogList({Key? key, required this.entries}) : super(key: key);

  /// Rows of [date, time, event, door], as the report endpoints return them.
  final List<List<String>> entries;

  static bool _isEntry(List<String> e) => e.length >= 4 && e[0].isNotEmpty;

  String _formatDate(String raw) {
    try {
      final d = DateTime.parse(raw);
      return '${d.day.toString().padLeft(2, '0')}.'
          '${d.month.toString().padLeft(2, '0')}.${d.year}';
    } catch (_) {
      return raw;
    }
  }

  String _weekday(String raw) {
    const names = [
      'Понедельник', 'Вторник', 'Среда', 'Четверг',
      'Пятница', 'Суббота', 'Воскресенье',
    ];
    try {
      return names[DateTime.parse(raw).weekday - 1];
    } catch (_) {
      return '';
    }
  }

  bool _isToday(String raw) {
    try {
      final d = DateTime.parse(raw);
      final now = DateTime.now();
      return d.year == now.year && d.month == now.month && d.day == now.day;
    } catch (_) {
      return false;
    }
  }

  /// True for an entry event; the label wording varies by locale and source.
  bool _isEntryEvent(String event) {
    final e = event.toLowerCase();
    return e.contains('вход') || e.contains('кіру') || e.contains('in');
  }

  @override
  Widget build(BuildContext context) {
    final rows = entries.where(_isEntry).toList();
    if (rows.isEmpty) return const SizedBox.shrink();

    // Preserve the order the report arrived in, grouping consecutive days.
    final days = <String, List<List<String>>>{};
    for (final row in rows) {
      days.putIfAbsent(row[0], () => []).add(row);
    }

    final children = <Widget>[];
    days.forEach((date, dayRows) {
      children.add(_dayHeader(context, date, dayRows.length));
      children.addAll(dayRows.map((r) => _row(context, r)));
      children.add(const SizedBox(height: 10));
    });

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _dayHeader(BuildContext context, String date, int count) {
    final today = _isToday(date);
    final weekday = _weekday(date);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6, left: 4, right: 4),
      child: Row(
        children: [
          Text(
            _formatDate(date),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: today ? context.accentColor : context.mutedColor,
            ),
          ),
          if (weekday.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              weekday,
              style: TextStyle(fontSize: 12, color: context.mutedColor),
            ),
          ],
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: (today ? context.accentColor : context.mutedColor).withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: today ? context.accentColor : context.mutedColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, List<String> entry) {
    final isIn = _isEntryEvent(entry[2]);
    final accent = isIn ? AppColors.mainColor : Colors.orange.shade800;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onLongPress: () {
            final line =
                '${_formatDate(entry[0])}  ${entry[1]}  ${entry[2]}  ${entry[3]}';
            Clipboard.setData(ClipboardData(text: line));
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('copied'.tr),
              duration: const Duration(seconds: 1),
            ));
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  isIn ? Icons.login : Icons.logout,
                  size: 18,
                  color: accent,
                ),
                const SizedBox(width: 10),
                Text(
                  entry[1],
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  entry[2],
                  style: TextStyle(fontSize: 13, color: accent),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    entry[3],
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: context.mutedColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
