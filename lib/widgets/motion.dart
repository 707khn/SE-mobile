import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Движение в приложении — одно на все экраны.
///
/// Длительности и кривые собраны здесь, чтобы переход страницы, смена
/// вкладки и появление карточек двигались в одном темпе: разнобой глаз
/// замечает раньше, чем саму анимацию.
class Motion {
  const Motion._();

  static const Duration page = Duration(milliseconds: 320);
  static const Duration tab = Duration(milliseconds: 240);
  static const Duration enter = Duration(milliseconds: 420);

  /// Быстрый старт и мягкая остановка — движение «приезжает», а не тормозит.
  static const Curve curve = Curves.easeOutCubic;

  /// Человек отключил анимации в системе («Удалить анимацию» на Android,
  /// «Уменьшить движение» на iPhone) — уважаем.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;
}

/// Переход между страницами: новая выезжает справа на несколько процентов
/// ширины и проявляется, прежняя чуть уходит влево.
///
/// Прежний «купертиновский» сдвиг на всю ширину на Android и на компьютере
/// выглядел чужим и тяжёлым: экран целиком ездил туда-сюда на каждый тап.
/// Короткий сдвиг с проявлением читается как «открылось поверх», а не как
/// «пролистнулось».
///
/// Прежняя страница остаётся непрозрачной: если гасить обе, посередине
/// перехода сквозь них просвечивает пустое окно.
class FadeThroughSlideTransition extends CustomTransition {
  @override
  Widget buildTransition(
    BuildContext context,
    Curve? curve,
    Alignment? alignment,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (Motion.reduced(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    final enter = CurvedAnimation(
      parent: animation,
      curve: Motion.curve,
      reverseCurve: Curves.easeInCubic,
    );
    final leave =
        CurvedAnimation(parent: secondaryAnimation, curve: Motion.curve);
    return SlideTransition(
      position:
          Tween(begin: Offset.zero, end: const Offset(-0.05, 0)).animate(leave),
      child: SlideTransition(
        position: Tween(begin: const Offset(0.08, 0), end: Offset.zero)
            .animate(enter),
        child: FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: const Interval(0, 0.7, curve: Curves.easeOut),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Появление при первом показе: снизу вверх с проявлением.
///
/// [index] сдвигает начало — карточки сетки появляются одна за другой, а не
/// разом. Играет один раз: вкладки живут в IndexedStack, и при возвращении
/// на вкладку содержимое не должно появляться заново.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  /// Шаг между соседями. Больше восьми ступеней не копим: в длинном списке
  /// последний ждал бы своей очереди дольше, чем человек — его.
  static const Duration step = Duration(milliseconds: 45);

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.enter + FadeSlideIn.step * widget.index.clamp(0, 8),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isAnimating || _c.isCompleted) return;
    if (Motion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _c.duration!.inMilliseconds;
    final start = total == 0 ? 0.0 : 1 - Motion.enter.inMilliseconds / total;
    final t = CurvedAnimation(
      parent: _c,
      curve: Interval(start, 1, curve: Motion.curve),
    );
    return FadeTransition(
      opacity: t,
      child: SlideTransition(
        position:
            Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(t),
        child: widget.child,
      ),
    );
  }
}

/// Плитка чуть утапливается под пальцем — видно, что нажатие принято, ещё
/// до того, как откроется экран.
class PressScale extends StatefulWidget {
  const PressScale({super.key, required this.child});

  final Widget child;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  Offset _origin = Offset.zero;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    // Listener, а не GestureDetector: он не спорит за жест с InkWell внутри.
    return Listener(
      onPointerDown: (e) {
        _origin = e.position;
        _set(true);
      },
      // Палец повёл — значит, листают, а не нажимают: плитка отпускается.
      onPointerMove: (e) {
        if ((e.position - _origin).distance > kTouchSlop) _set(false);
      },
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down && !Motion.reduced(context) ? 0.96 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
