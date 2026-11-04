import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:se_mobile/utils/api.dart';
import 'package:se_mobile/utils/notice_badge.dart';
import 'package:se_mobile/utils/variables.dart';

/// Уведомления на телефон через Firebase Cloud Messaging.
///
/// Пока приложение закрыто или свёрнуто, уведомление показывает сам Android
/// — по заголовку и тексту, которые прислал сервер, в канале, который он
/// назвал. Код приложения в этот момент не работает, и не должен: поэтому
/// фонового обработчика нет. Открыто приложение — Firebase уведомление не
/// показывает, и это делаем мы, через flutter_local_notifications.
///
/// Без настройки Firebase в сборке (google-services.json из секрета
/// GOOGLE_SERVICES_JSON) всё здесь молча ничего не делает.
class FcmService {
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  /// Значок в строке состояния — белый силуэт колокольчика. Цветной значок
  /// приложения Android рисует там сплошным белым кругом. Тот же значок
  /// назначен уведомлениям Firebase в AndroidManifest.xml.
  static const String _icon = 'ic_stat_notify';

  /// Каналы уведомлений по поводам.
  ///
  /// Раздельно, а не одним каналом на всё: Android даёт человеку отключить
  /// канал, не отключая приложение целиком. Сторожу нужны проходы турникета,
  /// остальным — зарплата и столовая, и пусть каждый оставит своё.
  ///
  /// Те же имена называет сервер (_PUSH_CHANNELS в app.py). Канала, которого
  /// на телефоне нет, Android не знает и кладёт уведомление в общий —
  /// поэтому каналы создаются при запуске, а не при первом уведомлении.
  static const Map<String, List<String>> _channels = {
    'payslip': ['payslip_channel', 'Зарплата'],
    'menu': ['menu_channel', 'Столовая'],
    'news': ['news_channel', 'Новости и объявления'],
    'turnstile': ['turnstile_channel', 'Проходы турникета'],
  };
  static const List<String> _general = ['general_channel', 'Прочее'];

  static AndroidNotificationDetails _androidDetails(String? type) {
    final channel = _channels[type] ?? _general;
    return AndroidNotificationDetails(
      channel[0],
      channel[1],
      icon: _icon,
      importance: Importance.high,
      priority: Priority.high,
    );
  }

  static StreamSubscription<RemoteMessage>? _onMessage;

  /// При запуске, когда Firebase поднялся: каналы и показ уведомлений, пока
  /// приложение открыто.
  ///
  /// Прежде при запуске ставился только показ, а подготовка уведомлений
  /// (init) не вызывалась нигде: показывать пришедшее было нечем, каналов
  /// «Зарплата», «Столовая» на телефоне не появлялось, а Android 13 и новее
  /// не спрашивал разрешения — и не показывал ничего.
  ///
  /// Не ждём: запуск приложения уведомлений не дожидается.
  static Future<void> setup() async {
    _onMessage ??= FirebaseMessaging.onMessage.listen(_showInForeground);
    if (!Platform.isAndroid) {
      // На iPhone открытому приложению уведомление показывает сама система
      // — надо лишь разрешить.
      try {
        await FirebaseMessaging.instance
            .setForegroundNotificationPresentationOptions(
                alert: true, badge: true, sound: true);
      } catch (_) {}
      return;
    }
    try {
      await _localNotifications.initialize(const InitializationSettings(
          android: AndroidInitializationSettings(_icon)));
      final android = _localNotifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      for (final channel in [..._channels.values, _general]) {
        await android?.createNotificationChannel(AndroidNotificationChannel(
          channel[0],
          channel[1],
          importance: Importance.high,
        ));
      }
    } catch (_) {}
  }

  static void _showInForeground(RemoteMessage message) {
    // Число на колокольчике — сразу: то же оповещение уже лежит в ленте.
    NoticeBadge.refresh();
    final notification = message.notification;
    if (notification == null || !Platform.isAndroid) return;
    _localNotifications
        .show(
          notification.hashCode,
          notification.title,
          notification.body,
          NotificationDetails(
            android: _androidDetails(message.data['type'] as String?),
          ),
        )
        .catchError((_) {});
  }

  /// Подписка на смену токена — одна на весь процесс: раньше каждая
  /// регистрация добавляла ещё одну.
  static StreamSubscription<String>? _refresh;

  /// Firebase поднят: без google-services.json его нет, и тогда
  /// уведомлений нет вовсе — молча, приложение работает и без них.
  static bool get _ready => Firebase.apps.isNotEmpty;

  /// Привязать этот телефон к вошедшему сотруднику.
  ///
  /// Раньше функция была, но её никто не вызывал, а пропуска она не
  /// посылала — после включения проверки входа сервер отказал бы ей. То есть
  /// уведомления не заработали бы и после подключения Firebase.
  static Future<void> registerToken(String employeeId) async {
    if (!_ready || employeeId.isEmpty) return;
    try {
      // Android 13 и новее без разрешения уведомлений не показывает вовсе.
      // Спрашиваем здесь, после входа, а не при запуске: на экране входа
      // «разрешить уведомления?» непонятно о чём. Ответил однажды — система
      // больше не спрашивает, и этот вызов просто возвращает ответ.
      await FirebaseMessaging.instance.requestPermission(
          alert: true, badge: true, sound: true);
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await _send(employeeId, token);
      await _refresh?.cancel();
      _refresh = FirebaseMessaging.instance.onTokenRefresh
          .listen((newToken) => _send(employeeId, newToken));
    } catch (_) {}
  }

  static Future<void> _send(String employeeId, String token) async {
    try {
      await http
          .post(
            Uri.parse('${AppValues.baseUrl}/api/fcm-token'),
            headers: await authHeaders(),
            body: jsonEncode({'employee_id': employeeId, 'token': token}),
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {}
  }

  /// Отвязать телефон при выходе — пока пропуск ещё действует.
  ///
  /// Иначе после смены пользователя на этом телефоне продолжали бы
  /// появляться уведомления прежнего: о его листке, его проходах. Токен
  /// заодно сбрасывается, и следующий вошедший получит новый.
  ///
  /// Сам токен сбрасывается и тогда, когда сервер не ответил: без связи
  /// раньше дело до сброса не доходило, и уведомления прежнего продолжали
  /// приходить, пока сервер помнил его токен. Сброшенный токен Firebase
  /// больше не доставляет, что бы ни помнил сервер.
  ///
  /// Каждый шаг ограничен по времени: без связи getToken может ждать долго,
  /// а человек нажал «Выйти» и смотрит на экран.
  static Future<void> unregisterToken() async {
    if (!_ready) return;
    await _refresh?.cancel();
    _refresh = null;
    try {
      final token = await FirebaseMessaging.instance
          .getToken()
          .timeout(const Duration(seconds: 5));
      if (token != null) {
        await http
            .delete(
              Uri.parse('${AppValues.baseUrl}/api/fcm-token'),
              headers: await authHeaders(),
              body: jsonEncode({'token': token}),
            )
            .timeout(const Duration(seconds: 8));
      }
    } catch (_) {}
    try {
      await FirebaseMessaging.instance
          .deleteToken()
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}
