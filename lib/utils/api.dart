import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../screens/start_screen.dart';
import 'secure_storage_helper.dart';
import 'variables.dart';

/// Заголовки для любого запроса к серверу: тип содержимого и пропуск,
/// который сервер выдал при входе.
///
/// Пока пропуска нет — например, приложение только обновили, а человек ещё
/// не перезаходил — заголовок просто не добавляется. Сервер в переходном
/// режиме такой запрос пропустит и запишет в лог.
Future<Map<String, String>> authHeaders() async {
  final token = await SecureStorageHelper.instance.getToken();
  return {
    'Content-Type': 'application/json',
    if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
  };
}

/// Гасит пропуск на сервере при выходе, чтобы он не остался годным ещё месяц.
/// Сеть недоступна — молчим: локально пропуск всё равно будет стёрт.
Future<void> revokeToken() async {
  try {
    final token = await SecureStorageHelper.instance.getToken();
    if (token == null || token.isEmpty) return;
    await http.post(
      Uri.parse('${AppValues.baseUrl}/logout'),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 8));
  } catch (_) {
    // Выход из учётной записи не должен зависеть от связи.
  }
}

/// Сервер ответил «пропуск не годится»: срок вышел или запись отозвали.
bool isUnauthorized(http.Response response) => response.statusCode == 401;

/// Сервер ответил «эти данные не для вас».
bool isForbidden(http.Response response) => response.statusCode == 403;

bool _returningToLogin = false;

/// Возвращает на экран входа, когда пропуск перестал действовать.
///
/// Экранов, которые грузятся одновременно, бывает несколько, и все они
/// получат 401 разом — флаг не даёт открыть вход несколько раз подряд.
Future<void> returnToLogin() async {
  if (_returningToLogin) return;
  _returningToLogin = true;
  try {
    await SecureStorageHelper.instance.clearCredentials();
    CustomFormState.loginController.clear();
    CustomFormState.passwordController.clear();
    Get.offAll(() => const StartPage());
    Get.snackbar(
      'session_expired_title'.tr,
      'session_expired_body'.tr,
      snackPosition: SnackPosition.BOTTOM,
      margin: const EdgeInsets.all(12),
      duration: const Duration(seconds: 4),
    );
  } finally {
    _returningToLogin = false;
  }
}

/// Проверяет ответ и, если пропуск истёк, уводит на вход.
/// Возвращает true, когда ответ разбирать уже не нужно.
Future<bool> handledUnauthorized(http.Response response) async {
  if (!isUnauthorized(response)) return false;
  await returnToLogin();
  return true;
}
