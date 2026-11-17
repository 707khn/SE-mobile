import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../utils/app_theme.dart';
import '../utils/biometric.dart';
import '../utils/colors.dart';
import '../utils/desktop.dart';
import '../utils/dimensions.dart';
import '../utils/logout_helper.dart';
import '../utils/secure_storage_helper.dart';
import 'change_password_screen.dart';
import 'home_shell.dart';

/// Зачем экран нужен в каждом из трёх случаев.
enum PinMode {
  /// Код придумывают: сразу после первого входа.
  create,

  /// Код спрашивают: приложение открыли заново.
  unlock,

  /// Код меняют: человек пришёл из бокового меню.
  change,

  /// Код спрашивают заново: приложение пролежало в фоне дольше пяти минут.
  /// От [unlock] отличается только тем, куда вернуться: человек не открывает
  /// приложение заново, а возвращается на тот экран, где его свернул.
  relock,
}

/// Сколько раз подряд можно ошибиться, прежде чем код перестанет помогать.
///
/// Четыре цифры — это десять тысяч сочетаний; без счётчика их подобрал бы и
/// подросток за вечер. После пятой ошибки код и пропуск стираются, и вход
/// снова только по логину с паролем — как в первый раз.
const int pinMaxFails = 5;

/// Вход в приложение после успешной проверки логина и пароля.
///
/// Если код ещё не заведён — сначала он. Отсюда и после смены временного
/// пароля, чтобы «придумайте код» не оказалось двумя разными дорогами.
Future<void> enterApp({required String fullName, required String job}) async {
  if (await SecureStorageHelper.instance.hasPin()) {
    Get.offAll(() => HomeShell(fullName: fullName, job: job));
  } else {
    Get.offAll(() => PinScreen(
          mode: PinMode.create,
          fullName: fullName,
          job: job,
        ));
  }
}

/// Открыт ли сейчас экран кода.
///
/// Нужно замку на фон: если человек оставил телефон на «введите код» и
/// вернулся через час, второй такой же экран поверх первого ни к чему.
/// Смотрим на сам экран, а не на имя маршрута: при запуске экран кода стоит
/// в `home`, и маршрут у него — обычный «/».
bool get pinScreenIsOpen => _PinScreenState._open > 0;

/// Код для входа: четыре цифры вместо логина и пароля при каждом открытии.
class PinScreen extends StatefulWidget {
  const PinScreen({
    Key? key,
    required this.mode,
    this.fullName = '',
    this.job = '',
  }) : super(key: key);

  final PinMode mode;

  /// Нужны, чтобы после кода сразу открыть приложение, не перечитывая
  /// хранилище: при открытии их уже прочитали.
  final String fullName;
  final String job;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  /// Сколько экранов кода сейчас на виду — см. [pinScreenIsOpen].
  static int _open = 0;

  /// Что набрано сейчас.
  String _entered = '';

  /// Код, набранный на первом шаге: его ждём подтвердить повтором.
  String? _first;

  /// В режиме смены — старый код уже проверен, дальше как при создании.
  bool _oldConfirmed = false;

  String? _error;
  bool _busy = false;

  /// Можно войти по отпечатку: человек включил это в «Настройках», и датчик
  /// на месте. Отпечаток могли и стереть из телефона — тогда кнопки нет.
  bool _biometric = false;

  @override
  void initState() {
    super.initState();
    _open++;
    if (_unlocking) _prepareBiometric();
  }

  /// Окно датчика открываем сразу, не дожидаясь нажатия: ради этого
  /// отпечаток и включают. Закрыли окно — остаются код и кнопка с пальцем.
  Future<void> _prepareBiometric() async {
    if (!await SecureStorageHelper.instance.biometricEnabled()) return;
    if (!await Biometric.instance.available()) return;
    if (!mounted) return;
    setState(() => _biometric = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tryBiometric();
    });
  }

  Future<void> _tryBiometric() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await Biometric.instance.authenticate(biometricReason());
      if (!ok || !mounted) return;
      // Узнали палец — значит, телефон в руках у хозяина: прежние неверные
      // коды больше не в счёт, как и после верного кода.
      await SecureStorageHelper.instance.resetPinFails();
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      if (widget.mode == PinMode.relock) {
        Get.back();
      } else {
        await _openApp();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _open--;
    super.dispose();
  }

  bool get _askingOld => widget.mode == PinMode.change && !_oldConfirmed;

  /// Код спрашивают, а не придумывают.
  bool get _unlocking =>
      widget.mode == PinMode.unlock || widget.mode == PinMode.relock;

  @override
  Widget build(BuildContext context) {
    // Из «введите код» и обязательного «придумайте код» системная кнопка
    // «назад» никуда не ведёт: позади них приложения нет.
    return PopScope(
      canPop: widget.mode == PinMode.change,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: widget.mode == PinMode.change,
          title: Text(_title),
          actions: [
            if (widget.mode != PinMode.change)
              TextButton(
                onPressed: () => confirmAndLogout(context),
                child: Text('log_out_title'.tr,
                    style: const TextStyle(color: Colors.white)),
              ),
          ],
        ),
        // Когда места хватает — как раньше: подсказка посередине, цифры
        // внизу. Когда нет (крупный шрифт на маленьком телефоне, да ещё
        // пояснение «зачем код» сверху) — экран прокручивается, а не
        // обрезает нижний ряд клавиатуры.
        // На компьютере код набирают с клавиатуры — цифрами сверху или
        // справа и Backspace; кнопки на экране мышью тоже работают.
        body: Focus(
          autofocus: true,
          onKeyEvent: _onKey,
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (widget.mode == PinMode.create && _first == null)
                        _why()
                      else
                        const SizedBox.shrink(),
                      Padding(
                        padding: EdgeInsets.symmetric(
                            vertical: Dimensions.height30 / 2),
                        child: _prompt(),
                      ),
                      Column(
                        children: [
                          _keypad(),
                          if (_unlocking)
                            TextButton(
                              onPressed: _busy ? null : _forgot,
                              child: Text('pin_forgot'.tr),
                            ),
                          SizedBox(height: Dimensions.height30 / 2),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Цифра с клавиатуры — как нажатие на экране; Backspace стирает.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      if (!_busy) _erase();
      return KeyEventResult.handled;
    }
    final digit = _digitKeys[event.logicalKey];
    if (event is KeyDownEvent && digit != null) {
      if (!_busy) _press(digit);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Цифры верхнего ряда и цифрового блока — по клавише, а не по символу:
  /// символ зависит от раскладки и от NumLock.
  static final Map<LogicalKeyboardKey, String> _digitKeys = {
    for (final (i, key) in const [
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ].indexed)
      key: '$i',
    for (final (i, key) in const [
      LogicalKeyboardKey.numpad0,
      LogicalKeyboardKey.numpad1,
      LogicalKeyboardKey.numpad2,
      LogicalKeyboardKey.numpad3,
      LogicalKeyboardKey.numpad4,
      LogicalKeyboardKey.numpad5,
      LogicalKeyboardKey.numpad6,
      LogicalKeyboardKey.numpad7,
      LogicalKeyboardKey.numpad8,
      LogicalKeyboardKey.numpad9,
    ].indexed)
      key: '$i',
  };

  String get _title {
    switch (widget.mode) {
      case PinMode.create:
        return 'pin_create_title'.tr;
      case PinMode.unlock:
      case PinMode.relock:
        return 'pin_unlock_title'.tr;
      case PinMode.change:
        return 'pin_change_title'.tr;
    }
  }

  String get _hint {
    if (_askingOld) return 'pin_current_hint'.tr;
    if (_first != null) return 'pin_repeat_hint'.tr;
    if (_unlocking) return 'pin_unlock_hint'.tr;
    return 'pin_create_hint'.tr;
  }

  Widget _why() {
    return Container(
      margin: EdgeInsets.fromLTRB(Dimensions.width20, Dimensions.width20,
          Dimensions.width20, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.mainColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, color: context.accentColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(isDesktop ? 'pin_why_pc'.tr : 'pin_why'.tr,
                style: const TextStyle(fontSize: 13.5, height: 1.45)),
          ),
        ],
      ),
    );
  }

  Widget _prompt() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(_hint, style: const TextStyle(fontSize: 16)),
        SizedBox(height: Dimensions.height30),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(4, (i) {
            final filled = i < _entered.length;
            return Container(
              width: 16,
              height: 16,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: filled ? AppColors.mainColor : Colors.transparent,
                border: Border.all(
                  color: _error != null
                      ? Colors.red.shade700
                      : (filled ? AppColors.mainColor : context.hairlineColor),
                  width: 1.6,
                ),
              ),
            );
          }),
        ),
        SizedBox(height: Dimensions.height30 / 1.5),
        // Место под ошибку держим всегда: иначе поле при ошибке прыгает.
        SizedBox(
          height: 40,
          child: _error == null
              ? null
              : Padding(
                  padding: EdgeInsets.symmetric(horizontal: Dimensions.width20),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.red.shade700, fontSize: 13),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _keypad() {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '', '0', '<'];
    // Не шире телефонной: в окне на компьютере клавиши иначе разъезжаются на
    // всю ширину, вырастают по высоте и сталкивают «Забыли код?» за край.
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: Dimensions.width20 * 1.5),
          child: GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 3,
            childAspectRatio: 1.7,
            children: keys.map(_key).toList(),
          ),
        ),
      ),
    );
  }

  Widget _key(String value) {
    if (value.isEmpty) {
      // Слева от нуля пусто — там и место для пальца.
      if (!_biometric) return const SizedBox.shrink();
      return Semantics(
        button: true,
        label: 'biometric_button'.tr,
        child: InkWell(
          key: const ValueKey('biometric'),
          borderRadius: BorderRadius.circular(40),
          onTap: _busy ? null : _tryBiometric,
          child: Center(
            child: Icon(Icons.fingerprint,
                size: 30, color: context.accentColor),
          ),
        ),
      );
    }
    final isBackspace = value == '<';
    return InkWell(
      borderRadius: BorderRadius.circular(40),
      onTap: _busy ? null : () => isBackspace ? _erase() : _press(value),
      child: Center(
        child: isBackspace
            ? Icon(Icons.backspace_outlined, size: 22, color: context.mutedColor)
            : Text(value,
                style: const TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w500)),
      ),
    );
  }

  void _press(String digit) {
    if (_entered.length >= 4) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entered += digit;
      _error = null;
    });
    if (_entered.length == 4) _complete();
  }

  void _erase() {
    if (_entered.isEmpty) return;
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _error = null;
    });
  }

  /// Набрали четыре цифры — дальше зависит от того, зачем пришли.
  Future<void> _complete() async {
    final entered = _entered;
    setState(() => _busy = true);
    try {
      if (_askingOld) {
        await _checkOld(entered);
      } else if (_unlocking) {
        await _unlock(entered);
      } else {
        await _choose(entered);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Старый код при смене — под тем же счётчиком, что и при входе.
  ///
  /// Раньше здесь ошибаться можно было сколько угодно. Кто взял в руки
  /// открытый телефон, мог перебрать все десять тысяч сочетаний и узнать
  /// код — а его нередко ставят тот же, что на карте или на самом телефоне.
  Future<void> _checkOld(String entered) async {
    final secure = SecureStorageHelper.instance;
    final saved = await secure.getPin();
    if (!mounted) return;
    if (entered == saved) {
      await secure.resetPinFails();
      if (!mounted) return;
      setState(() {
        _oldConfirmed = true;
        _entered = '';
      });
    } else {
      await _wrongCode();
    }
  }

  Future<void> _unlock(String entered) async {
    final secure = SecureStorageHelper.instance;
    final saved = await secure.getPin();
    if (!mounted) return;

    if (entered == saved) {
      await secure.resetPinFails();
      if (!mounted) return;
      if (widget.mode == PinMode.relock) {
        Get.back();
      } else {
        await _openApp();
      }
      return;
    }

    await _wrongCode();
  }

  /// Неверный код: ещё одна ошибка в счёт, а пятая — выход.
  Future<void> _wrongCode() async {
    final fails = await SecureStorageHelper.instance.bumpPinFails();
    if (!mounted) return;
    if (fails >= pinMaxFails) {
      // Стираем всё и отправляем на обычный вход. Снаружи это выглядит как
      // «приложение попросило войти заново» — и это честно: подобравший код
      // не должен получить ни данных, ни пропуска.
      await forceLogout(message: 'pin_locked_out'.tr);
      return;
    }
    _reject('pin_wrong'.tr,
        extra: 'pin_attempts_left'.trParams({'count': '${pinMaxFails - fails}'}));
  }

  /// Первый шаг — запомнить, второй — сверить и сохранить.
  Future<void> _choose(String entered) async {
    if (_first == null) {
      // Любой код из четырёх цифр, в том числе 1111 и 1234: так попросило
      // предприятие. От подбора защищает не сложность кода, а счётчик —
      // после пяти неверных попыток приложение выходит из учётной записи.
      setState(() {
        _first = entered;
        _entered = '';
      });
      return;
    }

    if (entered != _first) {
      setState(() => _first = null);
      _reject('pin_mismatch'.tr);
      return;
    }

    await SecureStorageHelper.instance.savePin(entered);
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    if (widget.mode == PinMode.change) {
      Get.back();
      Get.snackbar('pin_changed'.tr, '',
          snackPosition: SnackPosition.BOTTOM,
          margin: const EdgeInsets.all(12));
    } else {
      await _offerBiometric();
      if (!mounted) return;
      await _openApp();
    }
  }

  /// Код придуман — предлагаем один раз входить и по отпечатку.
  ///
  /// Сами не включаем: не каждый хочет, чтобы приложение открывал палец.
  /// Отказался — включит потом в «Настройках».
  Future<void> _offerBiometric() async {
    if (!await Biometric.instance.available()) return;
    if (!mounted) return;
    final wants = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.fingerprint, size: 36),
        title: Text('biometric_offer_title'.tr),
        content: Text('biometric_offer_body'.tr),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('biometric_offer_no'.tr),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('biometric_offer_yes'.tr),
          ),
        ],
      ),
    );
    if (wants != true) return;
    // Включаем, только когда палец действительно прочитался: иначе на
    // следующем входе окно датчика открывалось бы впустую.
    if (await Biometric.instance.authenticate(biometricReason())) {
      await SecureStorageHelper.instance.setBiometricEnabled(true);
    }
  }

  /// Открывает приложение, перечитав имя и должность.
  ///
  /// Должность решает, какие экраны человек увидит, а меняет её отдел кадров
  /// на сервере. Запрос за ней уходит при запуске и, пока набирают код,
  /// обычно успевает вернуться; не успел или связи нет — берём сохранённое.
  Future<void> _openApp() async {
    final secure = SecureStorageHelper.instance;
    final fullName = await secure.getFullName() ?? widget.fullName;
    final job = await secure.getJob() ?? widget.job;

    // Пароль выданный (сбросили, пока человек был внутри, или значок на
    // iPhone вошёл из Safari по коду), а человек уже вошёл. Свой пароль
    // спрашиваем здесь, а не на входе: на вход теперь попадают редко.
    if (await secure.passwordExpired()) {
      Get.offAll(() => ChangePasswordScreen(
            fullName: fullName,
            job: job,
            currentPassword: '',
          ));
      return;
    }
    Get.offAll(() => HomeShell(fullName: fullName, job: job));
  }

  /// Ошибка: очищаем набранное, чтобы не пришлось стирать вручную.
  void _reject(String message, {String? extra}) {
    HapticFeedback.heavyImpact();
    setState(() {
      _entered = '';
      _error = extra == null ? message : '$message. $extra';
    });
  }

  Future<void> _forgot() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('pin_forgot'.tr),
        content: Text('pin_forgot_body'.tr),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('cancel'.tr),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('log in'.tr),
          ),
        ],
      ),
    );
    if (confirmed == true) await forceLogout();
  }
}
