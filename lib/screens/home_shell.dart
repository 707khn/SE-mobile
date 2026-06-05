import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../utils/colors.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          MainPage1(fullName: widget.fullName, job: widget.job),
          const PayslipPage(),
          const LeavePage(),
          const MenuScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (i) => setState(() => _selectedIndex = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.mainColor,
        unselectedItemColor: Colors.grey,
        items: [
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
    );
  }
}
