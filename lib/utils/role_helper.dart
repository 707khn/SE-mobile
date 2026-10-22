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

/// Кому нужен раздел «Медосмотр и выпуск»: водителям, медпункту, механикам,
/// заведующему ХО и руководству ДМТО. Остальным карточка на
/// главной ни к чему. Последнее слово — за сервером.
bool usesPreTrip(String job) {
  final lower = job.toLowerCase();
  return lower.contains('водител') ||
      lower.contains('медицин') ||
      lower.contains('механик') ||
      lower.contains('заведующий хо') ||
      (lower.contains('руководител') && lower.contains('дмто'));
}
