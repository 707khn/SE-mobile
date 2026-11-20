import 'package:flutter/widgets.dart';

/// Не в браузере: отступы уже знает сам Flutter. См. web_safe_area.dart.
class WebSafeArea extends StatelessWidget {
  const WebSafeArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
