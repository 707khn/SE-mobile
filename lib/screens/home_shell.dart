import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../utils/colors.dart';
import '../utils/role_helper.dart';
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
  late int _selectedIndex = widget.initialIndex;

  /// The admin account has no attendance, payslip or leave of its own, so the
  /// tabs would lead to empty screens. Only the admin panel is offered, from
  /// the Home tab — which makes the bar itself redundant.
  bool get _isAdmin => isSystemAdmin(widget.job);

  void _navigateTo(int index) => setState(() => _selectedIndex = index);

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
          setState(() => _selectedIndex = 0);
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: IndexedStack(
          index: _selectedIndex,
          children: [
            HomeScreen(
              fullName: widget.fullName,
              job: widget.job,
              onNavigate: _navigateTo,
            ),
            MainPage1(
              fullName: widget.fullName,
              job: widget.job,
              onNavigate: _navigateTo,
            ),
            PayslipPage(onNavigate: _navigateTo),
            LeavePage(onNavigate: _navigateTo),
            MenuScreen(onNavigate: _navigateTo, job: widget.job),
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
