import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../screens/change_password_screen.dart';
import '../screens/home_shell.dart';
import '../utils/dimensions.dart';
import '../utils/secure_storage_helper.dart';
import '../utils/variables.dart';

/// Чем закончилась попытка входа.
enum _Result {
  /// Логин и пароль подошли.
  success,

  /// Сервер ответил и сказал, что такой пары логин/пароль нет.
  wrongCredentials,

  /// Сервер не ответил или ответил ошибкой. Стоит попробовать ещё раз.
  serverProblem,

  /// Ждали дольше таймаута — обычно сервер ещё просыпается.
  timedOut,
}

class _Attempt {
  const _Attempt(this.result, {this.body, this.message});

  final _Result result;
  final Map<String, dynamic>? body;

  /// Готовый текст ошибки, если он зависит от кода ответа.
  final String? message;
}

/// Будит сервер, пока человек набирает логин.
///
/// На бесплатном тарифе сервер засыпает после простоя и просыпается 40–60
/// секунд. Если начать будить его при открытии окна входа, к моменту нажатия
/// «Войти» он обычно уже готов. Ошибки здесь неважны: вход попробует сам.
Future<void> warmUpServer() async {
  try {
    await http
        .get(Uri.parse(AppValues.baseUrl))
        .timeout(const Duration(seconds: 70));
  } catch (_) {
    // Разогрев необязателен.
  }
}

Future<void> loginToAccount(
    String login, String password, BuildContext context) async {
  var attempt = await _attemptLogin(login, password);

  // Первый запрос после сна сервера иногда обрывается у него внутри. Одна
  // тихая повторная попытка избавляет от «войдите ещё раз»: раньше человек
  // видел «логин не зарегистрирован» и заходил со второго раза вручную.
  if (attempt.result == _Result.serverProblem) {
    await Future.delayed(const Duration(seconds: 2));
    attempt = await _attemptLogin(login, password);
  }

  switch (attempt.result) {
    case _Result.success:
      final body = attempt.body!;
      await SecureStorageHelper.instance.saveCredentials(
        login: login,
        password: password,
        fullName: body['full_name'],
        job: body['job'],
        employeeId: body['employee_id'] ?? '',
        // Пропуск для всех дальнейших запросов. Старый сервер его не
        // присылает — тогда поле пустое и заголовок просто не уходит.
        token: body['token'] as String?,
      );
      // Временный пароль (равен табельному номеру) — сначала на смену:
      // пока он такой, учётная запись открыта любому, кто номер знает.
      if (body['must_change_password'] == true) {
        Get.to(() => ChangePasswordScreen(
              fullName: body['full_name'],
              job: body['job'],
              currentPassword: password,
            ));
      } else {
        // Everyone gets the bottom-nav shell; admin-only screens are surfaced
        // as extra quick-access cards inside it.
        Get.to(() => HomeShell(fullName: body['full_name'], job: body['job']));
      }
      break;
    case _Result.wrongCredentials:
      _showNotRegistered(context);
      break;
    case _Result.timedOut:
      _showNetworkError(context, 'server_not_responding'.tr);
      break;
    case _Result.serverProblem:
      _showNetworkError(context, attempt.message ?? 'connection_error'.tr);
      break;
  }
}

Future<_Attempt> _attemptLogin(String login, String password) async {
  try {
    final response = await http
        .post(
          Uri.parse('${AppValues.baseUrl}/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'login': login, 'password': password}),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      return _Attempt(_Result.serverProblem,
          message: '${'server_error'.tr} (${response.statusCode})');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['message'] == 'Success' && login != '') {
      return _Attempt(_Result.success, body: body);
    }
    // Сервер честно сообщил, что у него сломалась база, — это не повод
    // обвинять человека в неверном пароле.
    if (body['error'] == 'internal') {
      return _Attempt(_Result.serverProblem, message: 'server_error'.tr);
    }
    return const _Attempt(_Result.wrongCredentials);
  } on TimeoutException {
    return const _Attempt(_Result.timedOut);
  } catch (_) {
    return _Attempt(_Result.serverProblem, message: 'connection_error'.tr);
  }
}

void _showNotRegistered(BuildContext context) {
  if (!context.mounted) return;
  showDialog(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        contentPadding: EdgeInsets.symmetric(
            horizontal: Dimensions.width20 / 2,
            vertical: Dimensions.height30 / 6),
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
