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
  static Future<AppUpdate?> check() async {
    // Из Google Play обновляет только Play: своя загрузка apk там запрещена.
    if (kFromPlay) return null;
    try {
      final response = await http
          .get(Uri.parse('${AppValues.baseUrl}/api/app/latest'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final app = body['app'];
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
    } catch (_) {
      return null;
    }
  }

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
