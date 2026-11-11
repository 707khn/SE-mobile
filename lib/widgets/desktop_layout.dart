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
  /// Навигатор не переезжает, когда панель появляется или прячется (см.
  /// build). Ключ — страховка: если дерево вокруг всё же поменяется,
  /// навигатор переедет целиком, а не создастся заново и не закроет экраны.
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
        // Навигатор стоит на одном и том же месте дерева и с панелью, и без
        // неё: меняется только ширина панели. Прежде без панели навигатор
        // переезжал из Row наверх (по GlobalKey) — и переезд случался ровно
        // при выходе, когда экран входа уже показан, а оболочка закрывается.
        // На Windows 10 окно в этот момент переставало отвечать: на экране
        // оставались и панель вошедшего, и форма входа.
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: sidebar ? kDesktopSidebarWidth : 0,
              child: sidebar ? const _Sidebar() : null,
            ),
            SizedBox(
              width: sidebar ? 1 : 0,
              child: sidebar
                  ? VerticalDivider(width: 1, color: context.hairlineColor)
                  : null,
            ),
            Expanded(
              child: MediaQuery(
                data: sidebar
                    ? media.copyWith(
                        size: Size(media.size.width - kDesktopSidebarWidth - 1,
                            media.size.height),
                      )
                    : media,
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
