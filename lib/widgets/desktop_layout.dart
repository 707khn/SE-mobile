import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import '../utils/desktop.dart';
import 'app_drawer.dart';

/// Окно программы на компьютере.
///
/// После входа, на окне шире [kDesktopSidebarBreakpoint], разделы стоят
/// постоянной панелью слева на всю высоту окна, как в любой программе для
/// компьютера, а раздел — справа от неё. Прежде всё приложение было
/// телефоном шириной 800 точек посреди серого поля: слева от него узкая
/// полоска вкладок, а остальные разделы прятались за «≡».
///
/// До входа и на узком окне — колонка посередине, как раньше.
class DesktopLayout extends StatefulWidget {
  const DesktopLayout({super.key, required this.child});

  /// Навигатор приложения со всеми экранами.
  final Widget child;

  @override
  State<DesktopLayout> createState() => _DesktopLayoutState();
}

class _DesktopLayoutState extends State<DesktopLayout> {
  /// Навигатор переезжает в дереве, когда панель появляется или прячется.
  /// С ключом он переезжает целиком, а не создаётся заново — иначе вход или
  /// изменение размера окна закрывали бы все открытые экраны.
  final _navigatorKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: DesktopSession.active,
      builder: (context, session, _) {
        final media = MediaQuery.of(context);
        final sidebar =
            session && media.size.width >= kDesktopSidebarBreakpoint;
        final content = DesktopSidebarScope(
          shown: sidebar,
          child: DesktopFrame(
            maxWidth: session ? kDesktopWideContentWidth : kDesktopContentWidth,
            band: session,
            child: KeyedSubtree(key: _navigatorKey, child: widget.child),
          ),
        );
        if (!sidebar) return content;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(
              width: kDesktopSidebarWidth,
              child: _Sidebar(),
            ),
            VerticalDivider(width: 1, color: context.hairlineColor),
            Expanded(
              child: MediaQuery(
                data: media.copyWith(
                  size: Size(media.size.width - kDesktopSidebarWidth - 1,
                      media.size.height),
                ),
                child: content,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Боковая панель — то же меню, что выдвигается на телефоне, только всегда
/// на виду.
class _Sidebar extends StatelessWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context) => const AppDrawer(permanent: true);
}
