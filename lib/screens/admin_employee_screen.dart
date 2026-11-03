import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../requests/admin_request.dart';
import '../utils/colors.dart';
import '../utils/initials.dart';
import '../utils/dimensions.dart';
import '../widgets/custom_text.dart';
import 'leave_screen.dart';
import 'main_screen_1.dart';
import 'payslip_screen.dart';
import '../utils/app_theme.dart';

/// Everything the admin panel knows about one employee, with links into the
/// existing report screens scoped to them.
class AdminEmployeeScreen extends StatelessWidget {
  const AdminEmployeeScreen({Key? key, required this.employee})
      : super(key: key);

  final AdminEmployee employee;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: 'admin_employee'.tr, color: Colors.white),
      ),
      body: ListView(
        padding: EdgeInsets.only(bottom: Dimensions.height30),
        children: [
          _buildHeader(context),
          SizedBox(height: Dimensions.height30 * 0.5),
          _sectionTitle(context, 'admin_data'.tr),
          _buildAction(
            context,
            icon: Icons.sensor_door,
            color: const Color(0xFF1565C0),
            label: 'attendance report'.tr,
            count: employee.accessCount,
            // MainPage1 needs a name and job for its header; the employeeId
            // switches it to this person's records and hides the viewer's
            // own profile drawer.
            onTap: () => Get.to(() => MainPage1(
                  fullName: employee.fullName,
                  job: employee.jobTitle,
                  employeeId: employee.employeeId,
                )),
          ),
          _buildAction(
            context,
            icon: Icons.receipt_long,
            color: AppColors.mainColor,
            label: 'payslip'.tr,
            count: employee.payslipCount,
            onTap: () => Get.to(() => PayslipPage(
                  employeeId: employee.employeeId,
                  employeeName: employee.fullName,
                )),
          ),
          _buildAction(
            context,
            icon: Icons.beach_access,
            color: const Color(0xFFE65100),
            label: 'leave_sick_days'.tr,
            count: employee.leaveCount,
            onTap: () =>
                Get.to(() => LeavePage(employeeId: employee.employeeId)),
          ),
          SizedBox(height: Dimensions.height30 * 0.5),
          _sectionTitle(context, 'admin_access'.tr),
          _PayrollSwitch(employee: employee),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final initials = initialsOf(employee.fullName);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
          Dimensions.width20, 0, Dimensions.width20, Dimensions.height30 * 0.7),
      color: AppColors.mainColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: Colors.white.withOpacity(0.2),
                child: Text(initials,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(employee.fullName,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 3),
                    Text(employee.jobTitle,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: Dimensions.height30 * 0.5),
          _field(context, 'admin_tab_number'.tr, employee.employeeId),
          if (employee.department.isNotEmpty)
            _field(context, 'admin_department'.tr, employee.department),
          if (employee.iin.isNotEmpty)
            _field(context, 'employee ID'.tr, employee.iin),
          _field(
            context,
            'login'.tr,
            employee.hasLogin ? employee.login : 'admin_no_login'.tr,
            dimmed: !employee.hasLogin,
          ),
        ],
      ),
    );
  }

  Widget _field(BuildContext context, String label, String value,
      {bool dimmed = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('copied'.tr),
            duration: const Duration(seconds: 1),
            behavior: SnackBarBehavior.floating,
          ));
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(label,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ),
            Expanded(
              child: Text(
                value,
                style: TextStyle(
                  color: dimmed ? Colors.white38 : Colors.white,
                  fontSize: 13,
                  fontStyle: dimmed ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) {
    return Padding(
      padding:
          EdgeInsets.fromLTRB(Dimensions.width20, 0, Dimensions.width20, 6),
      child: Text(
        text,
        style: TextStyle(
          color: context.accentColor,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildAction(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String label,
    required int count,
    required VoidCallback onTap,
  }) {
    final empty = count == 0;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: context.cardShadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          leading: Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          title: Text(label,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: Text(
            empty ? 'no_data'.tr : '${'records_count'.tr}: $count',
            style: TextStyle(
              fontSize: 12,
              color: empty
                  ? context.mutedColor.withOpacity(0.7)
                  : context.mutedColor,
            ),
          ),
          trailing: const Icon(Icons.chevron_right, size: 20),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
        ),
      ),
    );
  }
}

/// «Расчётная группа»: доступ к расчётным листам всего предприятия.
///
/// Кому он положен по должности, тому переключатель включён и не
/// выключается — это решает справочник. Остальным администратор открывает
/// его здесь, например бухгалтеру, записанной в 1С просто «Бухгалтер».
class _PayrollSwitch extends StatefulWidget {
  const _PayrollSwitch({required this.employee});

  final AdminEmployee employee;

  @override
  State<_PayrollSwitch> createState() => _PayrollSwitchState();
}

class _PayrollSwitchState extends State<_PayrollSwitch> {
  late bool _on = widget.employee.payroll;
  bool _saving = false;

  Future<void> _set(bool value) async {
    setState(() => _saving = true);
    final result = await setPayrollAccess(widget.employee.employeeId, value);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result != null) _on = result;
    });
    if (result == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('admin_payroll_failed'.tr)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final fixed = widget.employee.payrollByTitle;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: Dimensions.width20, vertical: 4),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: context.cardShadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SwitchListTile(
          key: const Key('admin_payroll'),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          secondary: const Icon(Icons.receipt_long_outlined),
          title: Text('admin_payroll'.tr,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: Text(
            fixed ? 'admin_payroll_by_title'.tr : 'admin_payroll_hint'.tr,
            style: TextStyle(fontSize: 12, color: context.mutedColor),
          ),
          value: _on,
          onChanged: fixed || _saving ? null : _set,
        ),
      ),
    );
  }
}
