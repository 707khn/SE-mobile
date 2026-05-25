import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:se_mobile/screens/admin_screen.dart';
import 'package:se_mobile/screens/start_screen.dart';
import 'package:se_mobile/utils/colors.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/role_helper.dart';
import 'package:se_mobile/utils/variables.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/main_screen_1.dart';
import 'screens/main_screen_2.dart';
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
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ru'),
      ],
      title: 'SemEng',
      theme: ThemeData(
          colorScheme: const ColorScheme(
            primary: AppColors.mainColor,
            background: AppColors.niceWhite,
            onSurface: Colors.black,
            surface: AppColors.niceWhite,
            onPrimary: AppColors.niceWhite,
            secondary: AppColors.mainColor,
            error: AppColors.niceRed,
            onBackground: Colors.black,
            brightness: Brightness.light,
            onError: AppColors.niceWhite,
            onSecondary: AppColors.niceWhite,
          )
      ),
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
              if (isAdminRole(job)){
                return AdminPage(fullName: fullName, job: job);
              } else {
                return MainPage1(fullName: fullName, job: job);
              }
            } else {
              return const StartPage();
            }
          }
        },
      ),
      locale: Locale(prefs.getString(AppValues.LANG) ?? "KZ"),
      translations: LocaleString(),
    );
  }
  Future<Map<String, String?>> authCheck() async {
    final secure = SecureStorageHelper.instance;
    final isLogged = await secure.isLoggedIn();
    if (isLogged) {
      final empId = await secure.getEmployeeId();
      if (empId == null || empId.isEmpty) {
        await _refreshEmployeeId(secure);
      }
      return {
        'loggedIn': 'true',
        'fullName': await secure.getFullName(),
        'job': await secure.getJob(),
      };
    } else {
      return {'loggedIn': 'false'};
    }
  }

  Future<void> _refreshEmployeeId(SecureStorageHelper secure) async {
    final iin = await secure.getLogin();
    if (iin == null || iin.isEmpty) return;
    try {
      final r = await http.post(
        Uri.parse('${AppValues.baseUrl}/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'iin': iin}),
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final b = jsonDecode(r.body) as Map<String, dynamic>;
        if (b['message'] == 'Success') {
          final fresh = (b['employee_id'] as String?) ?? '';
          if (fresh.isNotEmpty) {
            await secure.saveEmployeeId(fresh);
          }
        }
      }
    } catch (_) {}
  }
}

  Future<void> _refreshEmployeeId(SecureStorageHelper secure) async {
    final iin = await secure.getLogin();
    if (iin == null || iin.isEmpty) return;
    try {
      final r = await http.post(
        Uri.parse('${AppValues.baseUrl}/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'iin': iin}),
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        final b = jsonDecode(r.body) as Map<String, dynamic>;
        if (b['message'] == 'Success') {
          final fresh = (b['employee_id'] as String?) ?? '';
          if (fresh.isNotEmpty) {
            await secure.saveEmployeeId(fresh);
          }
        }
      }
    } catch (_) {}
  }
}
