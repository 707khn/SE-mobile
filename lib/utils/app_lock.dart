import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../screens/pin_screen.dart';
import 'desktop.dart';
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

  /// Простой на компьютере: столько без мыши и клавиатуры — и снова код.
  ///
  /// В браузере и в программе для Windows окно не уходит в фон: человек
  /// открыл расчётный лист, отошёл от общего компьютера, а листок так и
  /// висит на экране. Телефонный замок «вернулись из фона» тут не сработает
  /// никогда, поэтому на компьютере считаем ещё и простой.
  static const Duration idleLimit = Duration(minutes: 5);

  /// Когда в последний раз трогали мышь или клавиатуру.
  DateTime _lastInput = DateTime.now();

  Timer? _idleTimer;

  /// Подписаны ли на мышь и клавиатуру — чтобы не подписаться дважды.
  bool _watching = false;

  /// Для тестов: `true` — считать простой, как на компьютере.
  @visibleForTesting
  static bool? debugWatchIdleOverride;

  /// Следить ли за простоем: в браузере и в программе для компьютера.
  bool get _watchIdle => debugWatchIdleOverride ?? (kIsWeb || isDesktop);

  void start() {
    WidgetsBinding.instance.addObserver(this);
    if (_watchIdle && !_watching) {
      _watching = true;
      _lastInput = DateTime.now();
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
      HardwareKeyboard.instance.addHandler(_onKey);
      _idleTimer =
          Timer.periodic(const Duration(seconds: 20), (_) => checkIdle());
    }
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_watching) {
      _watching = false;
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
  }

  void _onPointer(PointerEvent event) => _lastInput = DateTime.now();

  bool _onKey(KeyEvent event) {
    _lastInput = DateTime.now();
    return false; // клавишу не съедаем — она нужна полю ввода
  }

  /// Пора ли закрыть окно по простою. [now] — для тестов.
  @visibleForTesting
  Future<void> checkIdle({DateTime? now}) async {
    if (!_watchIdle) return;
    // В фоне — это дело замка «вернулись из фона».
    if (_leftAt != null) return;
    if ((now ?? DateTime.now()).difference(_lastInput) < idleLimit) return;
    await _lock();
    // После кода отсчёт начинается заново.
    _lastInput = DateTime.now();
  }

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
    await _lock();
  }

  Future<void> _lock() async {
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
