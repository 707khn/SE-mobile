import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../utils/colors.dart';
import 'home_screen.dart';
import 'leave_screen.dart';
import 'main_screen_1.dart';
import 'menu_screen.dart';
import 'payslip_screen.dart';

class HomeShell extends StatefulWidget {
  final String fullName;
  final String job;

  const HomeShell({Key? key, required this.fullName, required this.job})
      : super(key: key);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selectedIndex = 0;

  void _navigateTo(int index) => setState(() => _selectedIndex = index);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _selectedIndex == 0,
      onPopInvoked: (didPop) {
        if (!didPop) setState(() => _selectedIndex = 0);
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
              onBack: () => _navigateTo(0),
            ),
            PayslipPage(onBack: () => _navigateTo(0)),
            LeavePage(onBack: () => _navigateTo(0)),
            MenuScreen(onBack: () => _navigateTo(0), job: widget.job),
          ],
        ),
        bottomNavigationBar: NavigationBarTheme(
          data: NavigationBarThemeData(
            height: 64,
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            indicatorColor: AppColors.mainColor.withOpacity(0.14),
            labelTextStyle: MaterialStateProperty.resolveWith(
              (states) => TextStyle(
                fontSize: 11,
                fontWeight: states.contains(MaterialState.selected)
                    ? FontWeight.w600
                    : FontWeight.w400,
                color: states.contains(MaterialState.selected)
                    ? AppColors.mainColor
                    : Colors.grey.shade600,
              ),
            ),
            iconTheme: MaterialStateProperty.resolveWith(
              (states) => IconThemeData(
                size: 24,
                color: states.contains(MaterialState.selected)
                    ? AppColors.mainColor
                    : Colors.grey.shade600,
              ),
            ),
          ),
          child: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              if (index != _selectedIndex) HapticFeedback.selectionClick();
              _navigateTo(index);
            },
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.home_outlined),
                selectedIcon: const Icon(Icons.home),
                label: 'tab_home'.tr,
              ),
              NavigationDestination(
                icon: const Icon(Icons.sensor_door_outlined),
                selectedIcon: const Icon(Icons.sensor_door),
                label: 'tab_turnstile'.tr,
              ),
              NavigationDestination(
                icon: const Icon(Icons.receipt_long_outlined),
                selectedIcon: const Icon(Icons.receipt_long),
                label: 'tab_payslip'.tr,
              ),
              NavigationDestination(
                icon: const Icon(Icons.beach_access_outlined),
                selectedIcon: const Icon(Icons.beach_access),
                label: 'tab_leave'.tr,
              ),
              NavigationDestination(
                icon: const Icon(Icons.restaurant_menu_outlined),
                selectedIcon: const Icon(Icons.restaurant_menu),
                label: 'tab_menu'.tr,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
