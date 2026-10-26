import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../screens/change_password_screen.dart';
import '../screens/pin_screen.dart';
import '../utils/dimensions.dart';
import '../utils/load_problem.dart';
import '../widgets/load_error_view.dart';
import '../utils/login_lock.dart';
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

  /// Пять неверных попыток подряд — вход под этим логином закрыт на время.
  locked,
}

class _Attempt {
  const _Attempt(this.result,
      {this.body, this.problem, this.detail, this.retryAfter});

  final _Result result;
  final Map<String, dynamic>? body;

  /// Что случилось — для [_Result.serverProblem].
  final LoadProblem? problem;

  /// Техническая строка мелким шрифтом под объяснением: «HTTP 502»,
  /// «SocketException: Failed host lookup…». Человеку она ни к чему, а по
  /// снимку экрана из неё сразу видно, где искать.
  final String? detail;

  /// Через сколько секунд вход снова откроется — для [_Result.locked].
  final int? retryAfter;
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

  // Пока шёл запрос (до полутора минут с повтором), человек мог уйти с
  // экрана входа — показывать ошибку тогда не на чем.
  if (attempt.result != _Result.success && !context.mounted) return;

  switch (attempt.result) {
    case _Result.success:
      final body = attempt.body!;
      await SecureStorageHelper.instance.saveCredentials(
        login: login,
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
        // as extra quick-access cards inside it. Сначала код для входа, если
        // его ещё нет: дальше приложение открывается им.
        await enterApp(fullName: body['full_name'], job: body['job']);
      }
      break;
    case _Result.wrongCredentials:
      _showWrongCredentials(context);
      break;
    case _Result.locked:
      _showNetworkError(
          context, _lockedMessage(attempt.retryAfter),
          title: 'login_locked_title'.tr);
      break;
    case _Result.timedOut:
      _showProblem(context, LoadProblem.slow, null);
      break;
    case _Result.serverProblem:
      _showProblem(
          context, attempt.problem ?? LoadProblem.server, attempt.detail);
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

    // Пять неверных попыток — и сервер закрывает вход под этим логином,
    // отвечая 429 с «locked» и числом секунд до открытия. Раньше это
    // показывалось как «Ошибка сервера (429)»: человек думал, что сломан
    // сервер, и продолжал пробовать, хотя сервер прямо сказал, когда можно.
    if (response.statusCode == 429) {
      final retry = _retryAfter(response);
      return _Attempt(_Result.locked, retryAfter: retry);
    }
    if (response.statusCode != 200) {
      return _Attempt(_Result.serverProblem,
          problem: problemForStatus(response.statusCode),
          detail: 'HTTP ${response.statusCode}');
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (body['message'] == 'Success' && login != '') {
      return _Attempt(_Result.success, body: body);
    }
    // Сервер честно сообщил, что у него сломалась база, — это не повод
    // обвинять человека в неверном пароле.
    if (body['error'] == 'internal') {
      return const _Attempt(_Result.serverProblem,
          problem: LoadProblem.server, detail: 'error: internal');
    }
    return const _Attempt(_Result.wrongCredentials);
  } on TimeoutException {
    return const _Attempt(_Result.timedOut);
  } catch (e) {
    // Сюда попадает всё, где ответа-кода нет: нет сети, не нашёлся адрес,
    // не сошёлся сертификат, пришёл не JSON. Раньше на всё это было одно
    // «Ошибка подключения к серверу», и по снимку экрана нельзя было понять,
    // чинить ли телефон, сервер или сертификат.
    return _Attempt(_Result.serverProblem,
        problem: problemOf(e), detail: problemDetail(e));
  }
}

/// Логин и пароль не подошли.
///
/// Прежде здесь было «Данный логин не зарегистрирован!» — и это неправда
/// для всякого, кто просто ошибся в пароле, то есть почти для всех. Сервер
/// нарочно не говорит, что именно не подошло: иначе по ответам можно было бы
/// перебрать, какие табельные номера заведены. Значит, и приложение не
/// должно делать вид, что знает. «Не зарегистрирован» отправлял человека
/// искать беду с учётной записью, которой не было, — ровно так и вышло с
/// одной сотрудницей, чей логин был в порядке.
void _showWrongCredentials(BuildContext context) {
  if (!context.mounted) return;
  showDialog(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        contentPadding: EdgeInsets.symmetric(
            horizontal: Dimensions.width20,
            vertical: Dimensions.height30 / 2),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/logotype.png',
              height: Dimensions.height60 * 1.2,
              width: Dimensions.height60 * 1.2,
            ),
            const SizedBox(height: 8),
            Text(
              'login_wrong_title'.tr,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: Dimensions.fontSize16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'login_wrong_hint'.tr,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13.5, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('ok'.tr),
          ),
        ],
      );
    },
  );
}

/// «Попробуйте через N мин.» — из числа секунд, которое прислал сервер.
String _lockedMessage(int? seconds) {
  final minutes = lockMinutes(seconds);
  if (minutes == null) return 'login_locked_soon'.tr;
  return 'login_locked_wait'.trParams({'minutes': '$minutes'});
}

/// Сколько секунд ждать: из тела ответа, а если его нет — из заголовка.
int? _retryAfter(http.Response response) {
  try {
    final body = jsonDecode(response.body);
    if (body is Map && body['retry_after'] is num) {
      return (body['retry_after'] as num).toInt();
    }
  } catch (_) {}
  return int.tryParse(response.headers['retry-after'] ?? '');
}

/// Вход не удался не по вине человека: что случилось и что делать.
void _showProblem(BuildContext context, LoadProblem problem, String? detail) {
  if (!context.mounted) return;
  final (title, hint) = problemTexts(problem);
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hint),
          if (detail != null && detail.isNotEmpty) ...[
            const SizedBox(height: 12),
            SelectableText(
              detail,
              style: TextStyle(
                  fontSize: 11.5, color: Theme.of(dialogContext).hintColor),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text('ok'.tr),
        ),
      ],
    ),
  );
}

void _showNetworkError(BuildContext context, String message,
    {String? title}) {
  if (!context.mounted) return;
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title ?? 'error'.tr),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('ok'.tr),
        ),
      ],
    ),
  );
}
