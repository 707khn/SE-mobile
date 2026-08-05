import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:se_mobile/screens/start_screen.dart';
import 'package:se_mobile/utils/app_theme.dart';
import 'package:se_mobile/utils/colors.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/theme_pref.dart';
import 'package:se_mobile/utils/variables.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/home_shell.dart';
import 'utils/secure_storage_helper.dart';

// Firebase imports — only active when google-services.json / GoogleService-Info.plist are present
// ignore: depend_on_referenced_packages
import 'package:firebase_core/firebase_core.dart';
import 'services/fcm_service.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(dynamic message) async {
  await Firebase.initializeApp();
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  await initializeSharedPreferences();

  try {
    await Firebase.initializeApp();
    FcmService.setupForegroundHandler();
  } catch (_) {
    // Firebase not configured yet — app works without push notifications
  }

  runApp(const MyApp());
}

late SharedPreferences prefs;

Future<void> initializeSharedPreferences() async {
  prefs = await SharedPreferences.getInstance();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      debugShowCheckedModeBanner: false,
      // Smooth slide-in for pushed screens (reports, menu editor, …) instead
      // of the abrupt default.
      defaultTransition: Transition.cupertino,
      transitionDuration: const Duration(milliseconds: 260),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ru'),
      ],
      title: 'SemEng',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      // По умолчанию — как в телефоне; выбор переопределяется в боковом меню.
      themeMode: ThemePref.read(prefs),
      // Honour the phone's text-size setting — warehouse and canteen staff
      // often enlarge it — but cap the growth, since the denser screens
      // (payslip totals, turnstile rows) start overflowing beyond this.
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler
                .clamp(minScaleFactor: 1.0, maxScaleFactor: 1.3),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: FutureBuilder<Map<String, String?>>(
        future: authCheck(),
        builder: (context, res){
          if (res.connectionState == ConnectionState.waiting){
            return Scaffold(
              appBar: null,
              backgroundColor: AppColors.mainColor,
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/logo.png', height: 100, color: Colors.white),
                    const SizedBox(height: 24),
                    const CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  ],
                ),
              ),
            );
          } else {
            final data = res.data;
            if (data != null && data['loggedIn'] == 'true'){
              String fullName = data['fullName'] ?? '';
              String job = data['job'] ?? '';
              return HomeShell(fullName: fullName, job: job);
            } else {
              return const StartPage();
            }
          }
        },
      ),
      locale: Locale(prefs.getString(AppValues.LANG) ?? "RU"),
      translations: LocaleString(),
    );
  }
  Future<Map<String, String?>> authCheck() async {
    final secure = SecureStorageHelper.instance;
    final isLogged = await secure.isLoggedIn();
    if (isLogged) {
      // Always re-read the profile: job title and department drive which
      // screens a user sees, and HR edits them server-side. Offline, the
      // cached values below are used unchanged.
      await _refreshProfile(secure);
      return {
        'loggedIn': 'true',
        'fullName': await secure.getFullName(),
        'job': await secure.getJob(),
      };
    } else {
      return {'loggedIn': 'false'};
    }
  }

  Future<void> _refreshProfile(SecureStorageHelper secure) async {
    final login = await secure.getLogin();
    final password = await secure.getPassword();
    if (login == null || login.isEmpty || password == null || password.isEmpty) return;
    try {
      final r = await http.post(
        Uri.parse('${AppValues.baseUrl}/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'login': login, 'password': password}),
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final b = jsonDecode(r.body) as Map<String, dynamic>;
        if (b['message'] == 'Success') {
          await secure.saveProfile(
            fullName: (b['full_name'] as String?) ?? '',
            job: (b['job'] as String?) ?? '',
            employeeId: (b['employee_id'] as String?) ?? '',
          );
          // Заодно продлеваем пропуск: приложение открывают чаще, чем
          // перезаходят, и так срок практически не истекает.
          await secure.saveToken((b['token'] as String?) ?? '');
        }
      }
    } catch (_) {}
  }
}
