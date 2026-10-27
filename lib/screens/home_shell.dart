import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../services/fcm_service.dart';
import '../utils/desktop.dart';
import '../utils/role_helper.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/shell_tab.dart';
import 'home_screen.dart';
import 'leave_screen.dart';
import 'main_screen_1.dart';
import 'menu_screen.dart';
import 'payslip_screen.dart';
import '../utils/app_theme.dart';
import '../widgets/motion.dart';

class HomeShell extends StatefulWidget {
  final String fullName;
  final String job;

  /// Tab to open on. Lets the shared drawer land on a section when it has to
  /// rebuild the shell from a pushed screen.
  final int initialIndex;

  const HomeShell({
    Key? key,
    required this.fullName,
    required this.job,
    this.initialIndex = 0,
  }) : super(key: key);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int get _selectedIndex => ShellTab.selected.value;

  /// Вкладки, на которых человек уже побывал.
  ///
  /// IndexedStack создаёт всех своих детей сразу, а четверо из пяти при
  /// создании идут в сеть: расчётный лист — дважды, отпуска, меню. То есть
  /// запуск приложения отправлял пять-шесть запросов, четыре из них — за
  /// экранами, которые человек, может, и не откроет, и все они задерживали
  /// тот экран, который он открыть хотел.
  ///
  /// Вкладка создаётся, когда на неё заходят впервые, и дальше живёт: всё
  /// сохранённое на ней остаётся, как и раньше.
  late final Set<int> _visited = {widget.initialIndex};

  @override
  void initState() {
    super.initState();
    ShellTab.selected.value = widget.initialIndex;
    ShellTab.selected.addListener(_onTabChanged);
    _registerForPush();
  }

  /// Оболочка открывается после входа — по коду или по паролю, — и это
  /// единственное место, через которое проходят все. Без Firebase это
  /// ничего не делает.
  Future<void> _registerForPush() async {
    final id = await SecureStorageHelper.instance.getEmployeeId();
    if (id != null) await FcmService.registerToken(id);
  }

  @override
  void dispose() {
    ShellTab.selected.removeListener(_onTabChanged);
    super.dispose();
  }

  void _onTabChanged() {
    if (!mounted) return;
    setState(() => _visited.add(ShellTab.selected.value));
  }

  /// The admin account has no attendance, payslip or leave of its own, so the
  /// tabs would lead to empty screens. Only the admin panel is offered, from
  /// the Home tab — which makes the bar itself redundant.
  bool get _isAdmin => isSystemAdmin(widget.job);

  void _navigateTo(int index) => ShellTab.open(index);

  Widget _tab(int index) {
    switch (index) {
      case 1:
        return MainPage1(
          fullName: widget.fullName,
          job: widget.job,
          onNavigate: _navigateTo,
        );
      case 2:
        return PayslipPage(onNavigate: _navigateTo);
      case 3:
        return LeavePage(onNavigate: _navigateTo);
      case 4:
        return MenuScreen(onNavigate: _navigateTo, job: widget.job);
      default:
        return HomeScreen(
          fullName: widget.fullName,
          job: widget.job,
          onNavigate: _navigateTo,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Never let the shell be popped: below it sits the login screen, so
      // popping would silently sign the user back out. Back returns to the
      // Home tab, and on Home it leaves the app like any other root screen.
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        if (_selectedIndex != 0) {
          ShellTab.open(0);
        } else if (!isDesktop) {
          // На компьютере «назад» — это Esc, и на главной он не должен
          // закрывать окно: SystemNavigator.pop там завершает приложение.
          SystemNavigator.pop();
        }
      },
      child: LayoutBuilder(builder: (context, box) {
        // На компьютере вкладки — слева, как в любой программе для
        // компьютера: нижняя панель на мониторе далеко от глаз и от мыши.
        final rail = isDesktop && !_isAdmin && box.maxWidth >= 600;
        final stack = _TabFade(
          index: _selectedIndex,
          child: IndexedStack(
            index: _selectedIndex,
            children: [
              for (var i = 0; i < 5; i++)
                _visited.contains(i)
                    ? _tab(i)
                    // Ещё не открывали — и в сеть за ней не ходим.
                    : const SizedBox.shrink(),
            ],
          ),
        );
        return Scaffold(
          body: rail
              ? Row(
                  children: [
                    _rail(context),
                    VerticalDivider(width: 1, color: context.hairlineColor),
                    Expanded(child: stack),
                  ],
                )
              : stack,
          bottomNavigationBar: _isAdmin || rail ? null : _bottomBar(context),
        );
      }),
    );
  }

  static const List<(IconData, IconData, String)> _destinations = [
    (Icons.home_outlined, Icons.home, 'tab_home'),
    (Icons.sensor_door_outlined, Icons.sensor_door, 'tab_turnstile'),
    (Icons.receipt_long_outlined, Icons.receipt_long, 'tab_payslip'),
    (Icons.beach_access_outlined, Icons.beach_access, 'tab_leave'),
    (Icons.restaurant_menu_outlined, Icons.restaurant_menu, 'tab_menu'),
  ];

  void _select(int index) {
    if (index != _selectedIndex) HapticFeedback.selectionClick();
    _navigateTo(index);
  }

  Widget _rail(BuildContext context) {
    final accent = context.accentColor;
    return NavigationRail(
      selectedIndex: _selectedIndex,
      onDestinationSelected: _select,
      labelType: NavigationRailLabelType.all,
      backgroundColor: context.cardSurface,
      indicatorColor: accent.withValues(alpha: 0.14),
      selectedIconTheme: IconThemeData(color: accent),
      unselectedIconTheme: IconThemeData(color: context.mutedColor),
      selectedLabelTextStyle: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w600, color: accent),
      unselectedLabelTextStyle:
          TextStyle(fontSize: 12, color: context.mutedColor),
      destinations: [
        for (final (icon, active, label) in _destinations)
          NavigationRailDestination(
            icon: Icon(icon),
            selectedIcon: Icon(active),
            label: Text(label.tr),
          ),
      ],
    );
  }

  /// Нижняя панель в духе Material 3: выбранная вкладка — на зелёной
  /// «таблетке», которая перетекает от вкладки к вкладке. Цвета и размеры —
  /// в теме (navigationBarTheme), чтобы панель выглядела одинаково и в
  /// тёмной теме.
  Widget _bottomBar(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.hairlineColor)),
      ),
      child: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _select,
        destinations: [
          for (final (icon, active, label) in _destinations)
            NavigationDestination(
              icon: Icon(icon),
              selectedIcon: Icon(active),
              label: label.tr,
              tooltip: '',
            ),
        ],
      ),
    );
  }
}

/// Смена вкладки — мягким проявлением с лёгким подъёмом, а не скачком.
///
/// Сами вкладки остаются в IndexedStack и живут дальше: анимируется только
/// то, как новая показывается. Пересоздавать их ради анимации нельзя —
/// пропали бы открытый листок, выбранный период и прокрутка.
class _TabFade extends StatefulWidget {
  const _TabFade({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_TabFade> createState() => _TabFadeState();
}

class _TabFadeState extends State<_TabFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: Motion.tab, value: 1);
  late final Animation<double> _t =
      CurvedAnimation(parent: _c, curve: Motion.curve);

  @override
  void didUpdateWidget(_TabFade old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index && !Motion.reduced(context)) {
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _t,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.015), end: Offset.zero)
            .animate(_t),
        child: widget.child,
      ),
    );
  }
}
