import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../screens/start_screen.dart';
import 'app_version.dart';
import 'offline_cache.dart';
import 'secure_storage_helper.dart';
import 'variables.dart';

/// Заголовки для любого запроса к серверу: тип содержимого и пропуск,
/// который сервер выдал при входе.
///
/// Пока пропуска нет — например, приложение только обновили, а человек ещё
/// не перезаходил — заголовок просто не добавляется. Сервер в переходном
/// режиме такой запрос пропустит и запишет в лог.
///
/// Версию сборки приложение называет само. Без этого нельзя ответить на
/// единственный вопрос, который держит обязательную проверку пропуска
/// выключенной: дошла ли новая сборка до всех.
Future<Map<String, String>> authHeaders() async {
  final token = await SecureStorageHelper.instance.getToken();
  return {
    'Content-Type': 'application/json',
    'X-App-Version': appVersionLabel(),
    if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
  };
}

/// Табельный номер по пропуску — когда сохранённого на телефоне нет.
///
/// Такое бывает после обновления с очень старой сборки. Раньше для этого
/// приложение входило заново сохранённым паролем; теперь хватает пропуска.
Future<String?> employeeIdFromServer() async {
  try {
    final r = await http
        .get(Uri.parse('${AppValues.baseUrl}/api/me'), headers: await authHeaders())
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    if (body['message'] != 'Success') return null;
    final id = (body['employee_id'] as String?) ?? '';
    if (id.isEmpty) return null;
    await SecureStorageHelper.instance.saveEmployeeId(id);
    return id;
  } catch (_) {
    return null;
  }
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
    // И сохранённое для работы без связи: на одном телефоне может войти
    // другой человек, чужой расчётный лист ему видеть незачем.
    await OfflineCache.clear();
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
