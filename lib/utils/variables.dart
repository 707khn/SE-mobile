import 'package:flutter/foundation.dart' show kIsWeb;

class AppValues {
  static const String LANG = "Language";
  // Свой сервер в Астане (PS Cloud). До этого приложение ходило на
  // se-mobile.onrender.com — бесплатный тариф в США, засыпавший после
  // простоя, с базой во Франкфурте.
  //
  // Подменяется при сборке: `--dart-define=API_BASE_URL=http://127.0.0.1:5000`
  // — чтобы проверить сборку (например, для компьютера) на сервере,
  // запущенном у себя, не трогая настоящий.
  //
  // Веб-версия ходит на тот сервер, с которого её открыли: nginx раздаёт её
  // с api.se-btrz.com/web/, и запросы остаются на своём сайте — без CORS.
  static const String _configured = String.fromEnvironment('API_BASE_URL');
  static String get baseUrl => _configured.isNotEmpty
      ? _configured
      : kIsWeb
          ? Uri.base.origin
          : 'https://api.se-btrz.com';
}