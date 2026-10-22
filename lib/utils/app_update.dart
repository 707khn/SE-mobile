import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';
import 'store.dart';
import 'variables.dart';

/// Есть ли на сервере сборка новее той, что стоит на телефоне.
///
/// Приложение раздаётся руками: apk отправляют в переписке, ставит его тот,
/// кто дошёл. Из-за этого обязательную проверку пропуска нельзя включить —
/// у необновившихся всё перестанет работать, — и понять, кто обновился,
/// можно было только по их запросам к серверу.
///
/// Теперь сборка лежит на самом сервере, и приложение само говорит человеку,
/// что вышла новая.
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.build,
    required this.url,
    required this.sizeBytes,
  });

  final String version;
  final int build;
  final String url;
  final int sizeBytes;

  /// «46 МБ» — человек скачивает это по заводскому каналу и имеет право
  /// знать заранее.
  String get sizeLabel {
    if (sizeBytes <= 0) return '';
    final mb = sizeBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} МБ';
  }

  String get label => '$version ($build)';

  static const String _dismissedKey = 'updateDismissedBuild';

  /// Спрашивает сервер. null — сборки нет, она не новее, или связи нет.
  ///
  /// Никогда не бросает: проверка обновления, роняющая приложение, — худшее,
  /// что можно придумать.
  static Future<AppUpdate?> check() async => (await UpdateStatus.fetch())?.latest;

  static AppUpdate? fromJson(dynamic app) {
    if (app is! Map || app['available'] != true) return null;
    final build = (app['build'] as num?)?.toInt() ?? 0;
    // Сравниваем по номеру сборки: только его смотрит и Android, решая,
    // ставить ли поверх установленного.
    if (build <= currentBuild) return null;
    final url = (app['url'] as String?) ?? '';
    if (url.isEmpty) return null;
    return AppUpdate(
      version: (app['version'] as String?) ?? '',
      build: build,
      url: url,
      sizeBytes: (app['size'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, Object> toJson() => {
        'available': true,
        'version': version,
        'build': build,
        'url': url,
        'size': sizeBytes,
      };

  /// Номер сборки, стоящей на телефоне.
  static int get currentBuild => int.tryParse(kAppBuild) ?? 0;

  /// Про эту сборку человеку уже говорили, и он отложил.
  ///
  /// Откладывается именно сборка, а не обновления вообще: следующая
  /// спросит заново. Иначе один отказ означал бы «больше не напоминать
  /// никогда», а напомнить как раз и нужно.
  Future<bool> isDismissed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getInt(_dismissedKey) ?? 0) >= build;
    } catch (_) {
      return false;
    }
  }

  Future<void> dismiss() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_dismissedKey, build);
    } catch (_) {}
  }
}

/// Что сервер сказал о версиях: есть ли сборка новее и не устарела ли эта.
///
/// Минимальную сборку назначает администратор на экране «Обновление» (или
/// MIN_APP_BUILD на сервере). Ниже неё приложение дальше экрана «Нужно
/// обновить» не пускает: так всех переводят на сборку, которая умеет
/// пропуск, прежде чем включать его обязательную проверку.
class UpdateStatus {
  const UpdateStatus({required this.minBuild, this.latest});

  /// Ниже этой сборки работать нельзя. 0 — ограничения нет.
  final int minBuild;

  /// Сборка на сервере, если она новее установленной.
  final AppUpdate? latest;

  /// Эта сборка устарела — дальше экрана обновления не пускаем.
  ///
  /// Сборку из Google Play обновляет только Play, и выходит она там позже,
  /// чем на нашем сервере, — её не останавливаем: человек упёрся бы в
  /// экран, а обновления в магазине ещё нет.
  bool get required =>
      !kFromPlay && AppUpdate.currentBuild < minBuild;

  static const String _minKey = 'updateMinBuild';
  static const String _latestKey = 'updateRequiredApp';

  /// Спрашивает сервер. null — связи нет или ответ непонятный.
  static Future<UpdateStatus?> fetch() async {
    // Из Google Play обновляет только Play: своя загрузка apk там запрещена.
    if (kFromPlay) return null;
    try {
      final response = await http
          .get(Uri.parse('${AppValues.baseUrl}/api/app/latest'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final status = UpdateStatus(
        minBuild: (body['min_build'] as num?)?.toInt() ?? 0,
        latest: AppUpdate.fromJson(body['app']),
      );
      await status._remember();
      return status;
    } catch (_) {
      return null;
    }
  }

  /// Последний ответ сервера, сохранённый на телефоне.
  ///
  /// Без связи устаревшая сборка тоже не должна работать — иначе достаточно
  /// выключить сеть. И экран обновления должен показаться сразу при
  /// запуске, а не через восемь секунд ожидания сервера.
  static UpdateStatus remembered(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_latestKey);
      return UpdateStatus(
        minBuild: prefs.getInt(_minKey) ?? 0,
        latest: raw == null ? null : AppUpdate.fromJson(jsonDecode(raw)),
      );
    } catch (_) {
      return const UpdateStatus(minBuild: 0);
    }
  }

  Future<void> _remember() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_minKey, minBuild);
      final app = latest;
      if (app == null) {
        await prefs.remove(_latestKey);
      } else {
        await prefs.setString(_latestKey, jsonEncode(app.toJson()));
      }
    } catch (_) {}
  }
}
