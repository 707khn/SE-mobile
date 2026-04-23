import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:se_mobile/screens/admin_screen.dart';
import 'package:se_mobile/screens/start_screen.dart';
import 'package:se_mobile/utils/colors.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/variables.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/main_screen_1.dart';
import 'screens/main_screen_2.dart';
import 'utils/secure_storage_helper.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  await initializeSharedPreferences();
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
            background: Colors.red,
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
            return const Scaffold(
                appBar: null,
                body: Center(
                  child: CircularProgressIndicator(),
                )
            );
          } else {
            final data = res.data;
            if (data != null && data['loggedIn'] == 'true'){
              String fullName = data['fullName'] ?? '';
              String job = data['job'] ?? '';
              if (job.contains("Руководитель") || job.contains("руководитель") || job.contains("Начальник") || job.contains("начальник") || job.contains("Директор") || job.contains("директор")){
                return AdminPage(fullName: fullName, job: job,);
              } else {
                return MainPage1(fullName: fullName, job: job,);
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
      return {
        'loggedIn': 'true',
        'fullName': await secure.getFullName(),
        'job': await secure.getJob(),
      };
    } else {
      return {'loggedIn': 'false'};
    }
  }
}

