import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_screen_icon.dart';

/// SE-mobile открыт на iPhone или iPad во вкладке браузера, а не значком с
/// экрана «Домой». iPad, который называет себя Mac, Flutter узнаёт сам.
bool get iosBrowserTab =>
    debugIosBrowserTabOverride ??
    (kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        !openedFromHomeScreen);

/// Для тестов: `true` или `false` — притвориться, `null` — как на самом деле.
bool? debugIosBrowserTabOverride;

/// SE-mobile открыт на iPhone или iPad значком с экрана «Домой». У такого
/// значка своё хранилище, отдельно от Safari: вход из вкладки сюда сам не
/// попадает (см. web_handoff_request.dart).
bool get iosHomeScreenIcon =>
    debugIosHomeScreenIconOverride ??
    (kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        openedFromHomeScreen);

/// Для тестов: `true` или `false` — притвориться, `null` — как на самом деле.
bool? debugIosHomeScreenIconOverride;

/// Есть ли у человека свой пароль — по слову сервера (/api/me,
/// `has_password`). Нет — значит, он входил с телефона или из браузера по
/// одноразовому коду, пока свой пароль там не спрашивали, и «Настройки»
/// предлагают его задать.
class OwnPassword {
  OwnPassword._();

  /// true, пока сервер не сказал иного: старый сервер поля не присылает, а
  /// у всех, кто входил до этой версии, пароль свой.
  static final ValueNotifier<bool> has = ValueNotifier<bool>(true);
  static const _key = 'has_password';

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      has.value = prefs.getBool(_key) ?? true;
    } catch (_) {
      has.value = true;
    }
  }

  static Future<void> save(bool value) async {
    has.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (_) {}
  }
}
