import 'access_report.dart';
import 'offline_cache.dart';

/// Проходы, сохранённые на телефоне, — чтобы «Турникет» открывался без связи.
///
/// Проходы меняются раз в месяц, когда приносят выгрузку из СКУД, и
/// хранить их на телефоне почти так же надёжно, как спрашивать сервер. Но
/// неполные данные здесь опаснее пустых: проход, которого нет в копии,
/// выглядит как «в этот день не проходил». Поэтому копия знает, что в ней
/// есть: весь отчёт целиком или только отдельные периоды, — и без связи
/// отвечает лишь на то, что в ней действительно есть.
class AccessCache {
  AccessCache._();

  static String key(String employeeId) => 'report_$employeeId';

  /// Сколько отдельных периодов помнить. Больше и не нужно: человек
  /// смотрит «сегодня», «неделю» и «месяц».
  static const int _maxRanges = 20;

  /// Копия после полного отчёта (/report): в ней всё.
  static Map<String, dynamic> full(Map<String, dynamic> body) => {
        'report': body['report'] ?? const [],
        'coverage': body['coverage'],
        'full': true,
        'ranges': const [],
      };

  /// Копия после отчёта за период [from]..[to] (даты «yyyy-MM-dd»): старые
  /// записи этих дней заменяются новыми, остальное остаётся.
  static Map<String, dynamic> merge(Map<String, dynamic>? saved,
      Map<String, dynamic> body, String from, String to) {
    final kept = [
      for (final e in (saved?['report'] as List? ?? const []))
        if (!_inRange(e, from, to)) e,
    ];
    final ranges = [
      ...(saved?['ranges'] as List? ?? const []),
      [from, to],
    ];
    return {
      'report': [...kept, ...(body['report'] as List? ?? const [])],
      'coverage': body['coverage'] ?? saved?['coverage'],
      'full': saved?['full'] == true,
      'ranges': ranges.length > _maxRanges
          ? ranges.sublist(ranges.length - _maxRanges)
          : ranges,
    };
  }

  /// Ответ из копии: весь отчёт (без [from]/[to]) или за период. null — в
  /// копии этого нет, и показывать её нельзя.
  static AccessReport? answer(Map<String, dynamic>? saved,
      {String? from, String? to}) {
    if (saved == null) return null;
    final isFull = saved['full'] == true;
    if (from == null || to == null) {
      if (!isFull) return null;
    } else if (!isFull && !_covered(saved['ranges'], from, to)) {
      return null;
    }
    final entries = <List<String>>[
      for (final e in (saved['report'] as List? ?? const []))
        if (e is Map && (from == null || _inRange(e, from, to!)))
          [
            '${e['date'] ?? ''}',
            '${e['time'] ?? ''}',
            '${e['event'] ?? ''}',
            '${e['door'] ?? ''}',
          ],
    ]..sort((a, b) => '${a[0]} ${a[1]}'.compareTo('${b[0]} ${b[1]}'));
    final stamp = saved[OfflineCache.stampKey];
    return AccessReport(
      entries,
      AccessCoverage.fromJson(saved['coverage']),
      cachedAt: stamp is String ? DateTime.tryParse(stamp) : null,
    );
  }

  static bool _inRange(dynamic entry, String from, String to) {
    if (entry is! Map) return false;
    final date = '${entry['date'] ?? ''}';
    return date.compareTo(from) >= 0 && date.compareTo(to) <= 0;
  }

  static bool _covered(dynamic ranges, String from, String to) {
    if (ranges is! List) return false;
    for (final r in ranges) {
      if (r is List &&
          r.length == 2 &&
          '${r[0]}'.compareTo(from) <= 0 &&
          '${r[1]}'.compareTo(to) >= 0) {
        return true;
      }
    }
    return false;
  }
}
