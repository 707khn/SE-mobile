import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Добавляет в MediaQuery отступы безопасной зоны браузера
/// (env(safe-area-inset-*)), которых сам Flutter в вебе не знает.
/// См. web_safe_area.dart.
class WebSafeArea extends StatefulWidget {
  const WebSafeArea({super.key, required this.child});

  final Widget child;

  @override
  State<WebSafeArea> createState() => _WebSafeAreaState();
}

class _WebSafeAreaState extends State<WebSafeArea>
    with WidgetsBindingObserver {
  EdgeInsets _insets = EdgeInsets.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _read();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Поворот, открытая клавиатура, свёрнутая строка адреса — всё это меняет
  // размер окна, и отступы могли стать другими.
  @override
  void didChangeMetrics() => _read();

  void _read() {
    final insets = _query();
    if (insets != _insets && mounted) setState(() => _insets = insets);
  }

  static EdgeInsets _query() {
    try {
      final list = globalContext
          .callMethod<JSArray<JSNumber>?>('seSafeAreaInsets'.toJS)
          ?.toDart;
      if (list == null || list.length != 4) return EdgeInsets.zero;
      final v = [for (final n in list) n.toDartDouble];
      return EdgeInsets.fromLTRB(v[3], v[0], v[1], v[2]);
    } catch (_) {
      return EdgeInsets.zero;
    }
  }

  static EdgeInsets _max(EdgeInsets a, EdgeInsets b) => EdgeInsets.fromLTRB(
        math.max(a.left, b.left),
        math.max(a.top, b.top),
        math.max(a.right, b.right),
        math.max(a.bottom, b.bottom),
      );

  @override
  Widget build(BuildContext context) {
    if (_insets == EdgeInsets.zero) return widget.child;
    final media = MediaQuery.of(context);
    // Пока открыта клавиатура, низ закрыт ею, и полоска «домой» не мешает:
    // так же, как делает сам Flutter на телефоне.
    final padding = _max(media.padding, _insets);
    final keyboard = media.viewInsets.bottom > 0;
    return MediaQuery(
      data: media.copyWith(
        padding: keyboard ? padding.copyWith(bottom: media.padding.bottom) : padding,
        viewPadding: _max(media.viewPadding, _insets),
      ),
      child: widget.child,
    );
  }
}
