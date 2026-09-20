import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../screens/pin_screen.dart';
import 'secure_storage_helper.dart';

/// Замок на приложение, свёрнутое надолго.
///
/// Код спрашивают при запуске, но приложение редко запускают заново: Android
/// держит его в памяти сутками, и свёрнутое утром окно к вечеру открывается
/// там же, где его оставили. Поэтому считаем время в фоне: вернулись позже
/// пяти минут — снова код.
///
/// Пять минут, а не мгновенно: иначе код пришлось бы набирать после каждого
/// взгляда на часы или ответа на сообщение, и его начали бы делать из четырёх
/// одинаковых цифр, чтобы быстрее.
class AppLock with WidgetsBindingObserver {
  AppLock._();
  static final AppLock instance = AppLock._();

  static const Duration _grace = Duration(minutes: 5);

  /// Когда приложение ушло в фон. null — оно на виду.
  DateTime? _leftAt;

  /// Экран кода уже открыт: второй поверх него не нужен.
  bool _locked = false;

  void start() => WidgetsBinding.instance.addObserver(this);

  void stop() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // inactive сюда не входит намеренно: он приходит и когда человек
        // потянул шторку уведомлений, и при входящем звонке — приложение при
        // этом никуда не уходило.
        _leftAt ??= DateTime.now();
        break;
      case AppLifecycleState.resumed:
        _lockIfLongEnough();
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  Future<void> _lockIfLongEnough() async {
    final left = _leftAt;
    _leftAt = null;
    if (left == null || DateTime.now().difference(left) < _grace) return;
    if (_locked) return;
    if (!await SecureStorageHelper.instance.hasPin()) return;

    // Не поверх экрана кода и не поверх входа: там и так спрашивают.
    if (pinScreenIsOpen || Get.currentRoute.contains('StartPage')) return;

    _locked = true;
    await Get.to(() => const PinScreen(mode: PinMode.relock),
        fullscreenDialog: true);
    _locked = false;
  }
}
