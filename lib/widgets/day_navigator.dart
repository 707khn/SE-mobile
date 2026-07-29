import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../utils/colors.dart';
import '../utils/dimensions.dart';

/// Day-by-day header used by the screens that show one date at a time.
///
/// Beyond the arrows it names the weekday and opens a date picker on tap —
/// stepping a chevron twenty times to reach last month is not navigation.
class DayNavigator extends StatelessWidget {
  const DayNavigator({
    Key? key,
    required this.date,
    required this.onChanged,
    this.firstDate,
    this.lastDate,
  }) : super(key: key);

  final DateTime date;
  final ValueChanged<DateTime> onChanged;

  /// Bounds for the picker. Defaults to two years around today.
  final DateTime? firstDate;
  final DateTime? lastDate;

  bool get _isToday {
    final now = DateTime.now();
    return date.year == now.year && date.month == now.month && date.day == now.day;
  }

  String get _label {
    final day = DateFormat('d MMMM', 'ru').format(date);
    if (_isToday) return '${'today'.tr}, $day';
    // Capitalised by hand rather than via intl's helper, whose nullability
    // differs between versions.
    final weekday = DateFormat('EEEE', 'ru').format(date);
    final named = weekday.isEmpty
        ? weekday
        : weekday[0].toUpperCase() + weekday.substring(1);
    return '$named, $day';
  }

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: firstDate ?? DateTime(now.year - 2),
      lastDate: lastDate ?? DateTime(now.year + 2),
      locale: const Locale('ru'),
    );
    if (selected != null) onChanged(selected);
  }

  void _step(int days) {
    HapticFeedback.selectionClick();
    onChanged(date.add(Duration(days: days)));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.mainColor,
      padding: EdgeInsets.only(
        left: Dimensions.width20 / 2,
        right: Dimensions.width20 / 2,
        bottom: Dimensions.height30 * 0.5,
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, color: Colors.white, size: 30),
            onPressed: () => _step(-1),
          ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _pick(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        _label,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.arrow_drop_down, color: Colors.white70, size: 20),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, color: Colors.white, size: 30),
            onPressed: () => _step(1),
          ),
        ],
      ),
    );
  }
}

/// Wraps [child] so a horizontal fling moves one day, matching the payslip
/// screen. [enabled] is false while a request is in flight.
class DaySwipeDetector extends StatelessWidget {
  const DaySwipeDetector({
    Key? key,
    required this.child,
    required this.onChanged,
    required this.date,
    this.enabled = true,
  }) : super(key: key);

  final Widget child;
  final DateTime date;
  final ValueChanged<DateTime> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragEnd: !enabled
          ? null
          : (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity > 250) {
                onChanged(date.subtract(const Duration(days: 1)));
              } else if (velocity < -250) {
                onChanged(date.add(const Duration(days: 1)));
              }
            },
      child: child,
    );
  }
}
