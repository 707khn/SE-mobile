import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop.dart';

/// Нужен ли на этом устройстве свой пароль при первом входе.
///
/// На телефоне — нет: дальше человек входит кодом из четырёх цифр или
/// пальцем, и пароль, придуманный на первом экране, тут же забыл бы. На
/// компьютере и в браузере — да: там его спросят снова, а Safari может
/// стереть сохранённый вход сам.
bool get passwordNeededToStart => isDesktop || kIsWeb;

/// Есть ли у человека свой пароль — по слову сервера (/api/me,
/// `has_password`). Нет — значит, он вошёл с телефона по одноразовому коду,
/// и «Настройки» предлагают задать пароль для входа с компьютера.
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
