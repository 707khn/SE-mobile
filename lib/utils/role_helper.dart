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

/// Отдел кадров: «Специалист по кадрам», «Инспектор по кадрам», «Начальник
/// отдела кадров». Им открыта очередь заявок; администратору — тоже, чтобы
/// подменить. Правило то же, что на сервере.
bool isHrStaff(String job) => job.toLowerCase().contains('кадр');

bool canProcessHr(String job) => isHrStaff(job) || isSystemAdmin(job);
