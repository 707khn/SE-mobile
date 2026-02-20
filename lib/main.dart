import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:se_mobile/screens/admin_screen.dart';
import 'package:se_mobile/screens/start_screen.dart';
import 'package:se_mobile/utils/colors.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/variables.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/main_screen_1.dart';
import 'screens/main_screen_2.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  initializeSharedPreferences();
  await Future.delayed(const Duration(seconds: 1));
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
        Locale('ru', '')
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
      home: FutureBuilder(
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
            if (res.data == true){
              String fullName = prefs.getString('fullName')!;
              String job = prefs.getString('job')!;
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
  Future<bool> authCheck() async {
    await Future.delayed(const Duration(seconds: 1));
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey('loggedIn')){
      return true;
    } else {
      return false;
    }
  }
}

