import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/start_screen.dart';
import '../variables.dart';
import 'secure_storage_helper.dart';

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
  await SecureStorageHelper.instance.clearCredentials();
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  reportsEntries = [["", "", "", ""]];
  // The login form's controllers are static, so whatever the previous user
  // typed would still be sitting in the fields on the way back out.
  CustomFormState.loginController.clear();
  CustomFormState.passwordController.clear();
  Get.offAll(() => const StartPage());
}
