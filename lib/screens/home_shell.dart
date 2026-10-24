import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../chat/chat_bridge.dart';
import '../chat/chat_config.dart';
import '../services/fcm_service.dart';
import '../utils/colors.dart';
import '../utils/role_helper.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/shell_tab.dart';
import 'chat_screen.dart';
import 'home_screen.dart';
import 'leave_screen.dart';
import 'main_screen_1.dart';
import 'menu_screen.dart';
import 'payslip_screen.dart';
import '../utils/app_theme.dart';

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
    // Нажатие на уведомление чата открывает вкладку «Чат».
    ChatBridge.start();
  }

  /// Вкладок пять, а с чатом — шесть. Без адреса сервера чата в сборке
  /// (CHAT_URL) вкладки нет, и приложение выглядит как раньше.
  int get _tabCount => chatEnabled ? 6 : 5;

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
      case ChatBridge.tabIndex:
        return ChatScreen(onNavigate: _navigateTo);
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
      onPopInvoked: (didPop) async {
        if (didPop) return;
        // В чате «Назад» сперва закрывает окно или переписку внутри него.
        if (_selectedIndex == ChatBridge.tabIndex && await ChatBridge.back()) return;
        if (_selectedIndex != 0) {
          ShellTab.open(0);
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _selectedIndex,
          children: [
            for (var i = 0; i < _tabCount; i++)
              _visited.contains(i)
                  ? _tab(i)
                  // Ещё не открывали — и в сеть за ней не ходим.
                  : const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: _isAdmin
            ? null
            : Container(
          decoration: BoxDecoration(
            color: context.cardSurface,
            boxShadow: context.cardShadow,
          ),
          child: SafeArea(
            top: false,
            child: BottomNavigationBar(
              currentIndex: _selectedIndex,
              onTap: (index) {
                if (index != _selectedIndex) HapticFeedback.selectionClick();
                _navigateTo(index);
              },
              type: BottomNavigationBarType.fixed,
              backgroundColor: context.cardSurface,
              elevation: 0,
              selectedItemColor: AppColors.mainColor,
              unselectedItemColor: context.mutedColor,
              selectedFontSize: 11,
              unselectedFontSize: 11,
              selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600),
              items: [
                BottomNavigationBarItem(
                  icon: const Icon(Icons.home_outlined),
                  activeIcon: const Icon(Icons.home),
                  label: 'tab_home'.tr,
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.sensor_door_outlined),
                  activeIcon: const Icon(Icons.sensor_door),
                  label: 'tab_turnstile'.tr,
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.receipt_long_outlined),
                  activeIcon: const Icon(Icons.receipt_long),
                  label: 'tab_payslip'.tr,
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.beach_access_outlined),
                  activeIcon: const Icon(Icons.beach_access),
                  label: 'tab_leave'.tr,
                ),
                BottomNavigationBarItem(
                  icon: const Icon(Icons.restaurant_menu_outlined),
                  activeIcon: const Icon(Icons.restaurant_menu),
                  label: 'tab_menu'.tr,
                ),
                if (chatEnabled)
                  BottomNavigationBarItem(
                    icon: const _ChatTabIcon(active: false),
                    activeIcon: const _ChatTabIcon(active: true),
                    label: 'tab_chat'.tr,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Значок вкладки «Чат» с числом непрочитанных. Число приходит из клиента
/// чата — только число, без имён и названий.
class _ChatTabIcon extends StatelessWidget {
  const _ChatTabIcon({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(active ? Icons.forum : Icons.forum_outlined);
    return ValueListenableBuilder<int>(
      valueListenable: ChatBridge.unread,
      builder: (context, count, _) => count == 0
          ? icon
          : Badge(
              label: Text(count > 99 ? '99+' : '$count'),
              backgroundColor: AppColors.niceRed,
              child: icon,
            ),
    );
  }
}
