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

/// Кому в версии для компьютера показывать «Загрузить расчётные листки».
bool canUploadPayslips(String job) => isPayroll(job) || isSystemAdmin(job);
