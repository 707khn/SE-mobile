import 'package:flutter/material.dart';
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
            MainPage1(fullName: widget.fullName, job: widget.job),
            const PayslipPage(),
            const LeavePage(),
            const MenuScreen(),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: _navigateTo,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: AppColors.mainColor,
          unselectedItemColor: Colors.grey,
          selectedFontSize: 11,
          unselectedFontSize: 11,
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
    );
  }
}
