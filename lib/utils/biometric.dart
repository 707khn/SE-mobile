import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:local_auth/local_auth.dart';

/// Отпечаток пальца (или лицо) вместо кода.
///
/// Только как ускорение поверх кода: код остаётся, и если палец не читается —
/// мокрые руки, перчатки, порез — его всегда можно набрать. Пароль по-прежнему
/// спрашивают лишь при первом входе и после «Забыли код?».
///
/// Спрашиваем только биометрию, без запасного кода телефона: иначе в
/// приложение пускал бы и графический ключ экрана, который нередко знает вся
/// семья, а смысл кода приложения как раз в том, чтобы его не знали.
abstract class Biometric {
  /// Подменяется в тестах: настоящего датчика там нет.
  static Biometric instance = _LocalAuthBiometric();

  /// Есть ли на телефоне датчик и заведён ли хотя бы один отпечаток.
  Future<bool> available();

  /// Показывает системное окно «приложите палец». true — узнали.
  ///
  /// Отмена, ошибка, заблокированный после неудач датчик — всё это просто
  /// false: человек наберёт код. Свои неудачи датчик считает сам и после
  /// пяти отключается на время, так что в счётчик неверных кодов они не идут.
  Future<bool> authenticate(String reason);
}

class _LocalAuthBiometric implements Biometric {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<bool> available() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      final enrolled = await _auth.getAvailableBiometrics();
      return enrolled.isNotEmpty;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
      );
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// Подпись под окном датчика — та же, что на экране кода.
String biometricReason() => 'biometric_reason'.tr;
