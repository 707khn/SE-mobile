import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop.dart';
import 'home_screen_icon.dart';

/// Нужен ли на этом устройстве свой пароль при первом входе.
///
/// Только на компьютере: программу для Windows снова и снова открывают
/// логином и паролем. На телефоне — нет: дальше человек входит кодом из
/// четырёх цифр или пальцем, и пароль, придуманный на первом экране, тут же
/// забыл бы. В браузере — тоже нет: им открывают SE-mobile на iPhone, и всё
/// там как на телефоне. Кому пароль всё же нужен, задаёт его в «Настройках».
bool get passwordNeededToStart => isDesktop;

/// Гасить ли выданный пароль сразу, как с ним вошли.
///
/// Везде, где свой пароль при первом входе не нужен, — кроме вкладки
/// браузера на iPhone. Значок с экрана «Домой» помнит своё, отдельно от
/// Safari: кто вошёл во вкладке и потом поставил значок, входит со значка
/// заново. Погаси мы код во вкладке, входить там было бы уже нечем — только
/// по новому коду из ОИТиС. Поэтому во вкладке код остаётся, а гаснет при
/// входе со значка.
bool get spendIssuedPasswordHere => !passwordNeededToStart && !iosBrowserTab;

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
/// `has_password`). Нет — значит, он вошёл с телефона или из браузера по
/// одноразовому коду, и «Настройки» предлагают задать пароль для входа с
/// компьютера.
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
