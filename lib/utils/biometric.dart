import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:local_auth/local_auth.dart';
import 'package:local_auth_android/local_auth_android.dart';

/// Вход по отпечатку пальца или лицу — вместо четырёх цифр.
///
/// Только как удобство поверх кода, не вместо него: код остаётся всегда,
/// и любой сбой здесь — нет датчика, человек отменил окно, телефон
/// отказал — молча оставляет его на экране кода.
class Biometric {
  Biometric._();

  static final LocalAuthentication _auth = LocalAuthentication();

  /// Есть ли на телефоне датчик и заведён ли в нём хоть один палец или лицо.
  static Future<bool> available() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Показать системное окно. true — человек подтвердил себя.
  static Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'biometric_reason'.tr,
        // Только палец или лицо. Код экрана телефона здесь не нужен: у
        // приложения свой код, и он уже на экране.
        biometricOnly: true,
        authMessages: [
          AndroidAuthMessages(
            signInTitle: 'biometric_title'.tr,
            cancelButton: 'biometric_use_pin'.tr,
          ),
        ],
      );
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } on LocalAuthException {
      return false;
    }
  }
}
