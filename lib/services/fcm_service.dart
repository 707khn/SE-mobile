import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:se_mobile/utils/variables.dart';

class FcmService {
  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings =
        InitializationSettings(android: androidSettings);
    await _localNotifications.initialize(initSettings);

    await FirebaseMessaging.instance
        .requestPermission(alert: true, badge: true, sound: true);
  }

  static void setupForegroundHandler() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      if (notification == null) return;
      _localNotifications.show(
        notification.hashCode,
        notification.title,
        notification.body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'turnstile_channel',
            'СКУД уведомления',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    });
  }

  static Future<void> registerToken(String employeeId) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;

      await http.post(
        Uri.parse('${AppValues.BASE_URL}/api/fcm-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'employee_id': employeeId, 'token': token}),
      );

      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        await http.post(
          Uri.parse('${AppValues.BASE_URL}/api/fcm-token'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'employee_id': employeeId, 'token': newToken}),
        );
      });
    } catch (_) {}
  }

  static Future<void> unregisterToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await http.delete(
        Uri.parse('${AppValues.BASE_URL}/api/fcm-token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token}),
      );
    } catch (_) {}
  }
}
