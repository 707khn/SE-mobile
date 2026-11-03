import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

bool isAdminRole(String job) {
  final lower = job.toLowerCase();
  return lower.contains('руководитель') ||
      lower.contains('начальник') ||
      lower.contains('директор') ||
      lower.contains('главный') ||
      lower.contains('заместитель');
}

/// The system administrator account, which may inspect any employee.
bool isSystemAdmin(String job) =>
    job.toLowerCase().contains('администратор системы');

/// Who may change the canteen menu: the technologist whose job it is, and the
/// administrator, who has to be able to fix it when she cannot.
bool canEditMenu(String job) => isCanteenTech(job) || isSystemAdmin(job);

bool isCanteenTech(String job) {
  final lower = job.toLowerCase();
  return lower.contains('технолог') && lower.contains('столов');
}

/// Расчётная группа бухгалтерии: она загружает расчётные листки из 1С. Так
/// же решает и сервер (payslip_questions.is_payroll), а он — последнее слово:
/// кого он добавил списком PAYROLL_STAFF, приложение по должности не узнает.
bool isPayroll(String job) {
  final lower = job.toLowerCase().replaceAll('ё', 'е').trim();
  return lower.contains('расчетн') || lower.startsWith('главный бухгалтер');
}

/// Кому в версии для компьютера показывать «Расчётные листы».
bool canUploadPayslips(String job) =>
    isPayroll(job) || isSystemAdmin(job) || PayrollAccess.granted.value;

/// Расчётная группа по слову сервера — /api/me, поле `payroll`.
///
/// По должности приложение узнаёт не всех: бухгалтера, которой раздел
/// открыли списком PAYROLL_STAFF на сервере, в справочнике зовут просто
/// «Бухгалтер». Ответ сервера помним между запусками: при старте /api/me
/// приходит не сразу, а без связи не приходит вовсе.
class PayrollAccess {
  PayrollAccess._();

  static final ValueNotifier<bool> granted = ValueNotifier<bool>(false);
  static const _key = 'payroll_access';

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      granted.value = prefs.getBool(_key) ?? false;
    } catch (_) {
      granted.value = false;
    }
  }

  static Future<void> save(bool value) async {
    granted.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (_) {}
  }
}
