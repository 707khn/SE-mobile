import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:se_mobile/screens/admin_screen.dart';
import '../screens/main_screen_1.dart';
import '../utils/dimensions.dart';
import '../utils/role_helper.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';

Future<void> loginToAccount(String login, BuildContext context) async {
  final secureStorage = SecureStorageHelper.instance;

  try {
    var response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'key_suffix': login}),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode == 200) {
      var responseBody = jsonDecode(response.body);
      if (responseBody['message'] == 'Success' && login != '') {
        String fullName = responseBody['full_name'];
        String job = responseBody['job'];
        await secureStorage.saveCredentials(
          login: login,
          fullName: fullName,
          job: job,
        );
        if (isAdminRole(job)) {
          Get.to(() => AdminPage(fullName: fullName, job: job));
        } else {
          Get.to(() => MainPage1(fullName: fullName, job: job));
        }
      } else {
        if (!context.mounted) return;
        showDialog(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              contentPadding: EdgeInsets.symmetric(horizontal: Dimensions.width20 / 2, vertical: Dimensions.height30 / 6),
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/logotype.png',
                    height: Dimensions.height60 * 1.5,
                    width: Dimensions.height60 * 1.5,
                  ),
                  Text(
                    'login_not_registered'.tr,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: Dimensions.fontSize16),
                  ),
                  SizedBox(height: Dimensions.height30 / 2),
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: Dimensions.height30 / 5),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      }
    } else {
      _showNetworkError(context, '${'server_error'.tr} (${response.statusCode})');
    }
  } on TimeoutException {
    _showNetworkError(context, 'server_not_responding'.tr);
  } catch (e) {
    _showNetworkError(context, 'connection_error'.tr);
  }
}

void _showNetworkError(BuildContext context, String message) {
  if (!context.mounted) return;
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text('error'.tr),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
