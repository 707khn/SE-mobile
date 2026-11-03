import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/chat_bridge.dart';
import '../functions/export_file.dart';
import '../screens/start_screen.dart';
import '../services/fcm_service.dart';
import '../variables.dart';
import 'notice_badge.dart';
import 'role_helper.dart';
import 'secure_storage_helper.dart';
import 'api.dart';

Future<void> confirmAndLogout(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('log_out_title'.tr),
      content: Text('log_out_confirm'.tr),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('cancel'.tr),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('log_out_title'.tr, style: const TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );

  if (confirmed != true) return;

  HapticFeedback.mediumImpact();
  await forceLogout();
}

/// Выход без вопросов: пять неверных кодов подряд, погашенный пропуск.
///
/// Спрашивать здесь нечего — решение уже принято, а `message` объясняет,
/// почему человек вдруг оказался на экране входа.
Future<void> forceLogout({String? message}) async {
  // Сначала отвязываем телефон от уведомлений — пока пропуск ещё годен.
  await FcmService.unregisterToken();
  // Выход из SE-mobile выводит и из чата: сессия чата отзывается, ключи под
  // ПИН-кодом и уведомления чата стираются с телефона.
  await ChatBridge.wipe();
  // Гасим пропуск на сервере, чтобы он не остался годным ещё месяц.
  // Не получилось — не беда: локально его всё равно стираем.
  await revokeToken();
  await SecureStorageHelper.instance.clearCredentials();
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  PayrollAccess.granted.value = false;
  try {
    await clearExports(await exportDirectory());
  } catch (_) {
    // Папки нет или она недоступна — стирать нечего.
  }
  reportsEntries = [["", "", "", ""]];
  NoticeBadge.reset();
  // The login form's controllers are static, so whatever the previous user
  // typed would still be sitting in the fields on the way back out.
  CustomFormState.loginController.clear();
  CustomFormState.passwordController.clear();
  Get.offAll(() => const StartPage());
  if (message != null && message.isNotEmpty) {
    Get.snackbar('log_out_title'.tr, message,
        snackPosition: SnackPosition.BOTTOM,
        margin: const EdgeInsets.all(12),
        duration: const Duration(seconds: 5));
  }
}
