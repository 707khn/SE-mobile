import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:se_mobile/screens/start_screen.dart';
import 'package:se_mobile/utils/app_theme.dart';
import 'package:se_mobile/utils/colors.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/theme_pref.dart';
import 'package:se_mobile/utils/variables.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/pin_screen.dart';
import 'utils/api.dart';
import 'utils/app_lock.dart';
import 'utils/error_log.dart';
import 'utils/lang.dart';
import 'utils/secure_storage_helper.dart';

// Firebase imports — only active when google-services.json / GoogleService-Info.plist are present
// ignore: depend_on_referenced_packages
import 'package:firebase_core/firebase_core.dart';
import 'services/fcm_service.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(dynamic message) async {
  await Firebase.initializeApp();
}

void main() {
  // Всё, включая поднятие привязки Flutter, происходит внутри одной зоны:
  // иначе приложение встречает человека сообщением «Zone mismatch» — а
  // ловить ошибки без зоны нельзя, и именно ради этого всё затевалось.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Ошибку, из-за которой приложение упало у человека в цехе, иначе не
    // узнать: телефон к отладчику не подключишь. Записываем на месте, читаем
    // в «О программе». Нужны обе дороги: FlutterError ловит сбои при
    // отрисовке, зона — всё остальное, включая асинхронное.
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      ErrorLog.record(details.exception, details.stack,
          where: details.library ?? '');
    };

    // Русские названия месяцев и дней недели — и казахские, если intl их
    // знает. Прежде готовились только русские, и переключённое на казахский
    // приложение показывало «июля 2026».
    await Lang.initDates();
    await initializeSharedPreferences();

    try {
      await Firebase.initializeApp();
      FcmService.setupForegroundHandler();
    } catch (_) {
      // Firebase not configured yet — app works without push notifications
    }

    // Следим, сколько приложение пролежало в фоне: вернулись позже пяти
    // минут — спросим код. Наблюдателя снимать некому и незачем: он живёт
    // столько же, сколько сам процесс.
    AppLock.instance.start();

    runApp(const MyApp());
  }, (error, stack) => ErrorLog.record(error, stack));
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
      // Здесь перечислено то, что умеет сам Flutter: выбор даты, кнопки «ОК»
      // и «Отмена», меню выделения текста. Пока в списке был один русский,
      // всё это оставалось русским даже у того, кто переключил приложение на
      // казахский.
      //
      // Казахский попадает в список, только если Flutter его знает: объявить
      // язык, которого у него нет, — значит уронить экран на
      // MaterialLocalizations.of. Не знает — эти надписи останутся русскими,
      // а текст самого приложения всё равно казахский.
      supportedLocales: Lang.supported,
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
              // Вход по коду: логин с паролем спрашивают только в первый раз
              // и после выхода. Кода ещё нет — значит, приложение обновили,
              // и придумать его нужно сейчас.
              return PinScreen(
                mode: data['hasPin'] == 'true' ? PinMode.unlock : PinMode.create,
                fullName: fullName,
                job: job,
              );
            } else {
              return const StartPage();
            }
          }
        },
      ),
      locale: Lang.locale(prefs.getString(AppValues.LANG)),
      fallbackLocale: const Locale(Lang.ru),
      translations: LocaleString(),
    );
  }
  Future<Map<String, String?>> authCheck() async {
    final secure = SecureStorageHelper.instance;
    // Пароль, оставшийся в хранилище от прежних сборок: теперь он не нужен
    // ни для чего, а лежать на телефоне ему незачем.
    await secure.forgetStoredPassword();
    final isLogged = await secure.isLoggedIn();
    if (isLogged) {
      // Always re-read the profile: job title and department drive which
      // screens a user sees, and HR edits them server-side. Offline, the
      // cached values below are used unchanged.
      //
      // Без await: пока человек набирает код, запрос успевает пройти, и
      // экран кода не ждёт сервер. Без связи ожидание было бы десятисекундным
      // — перед тем, как спросить четыре цифры, которые сервера не требуют.
      unawaited(_refreshProfile(secure).then((mustChange) async {
        if (mustChange) await secure.markPasswordExpired();
      }));
      return {
        'loggedIn': 'true',
        'fullName': await secure.getFullName(),
        'job': await secure.getJob(),
        'hasPin': (await secure.hasPin()).toString(),
      };
    } else {
      return {'loggedIn': 'false'};
    }
  }

  /// Перечитывает имя и должность по пропуску.
  ///
  /// Раньше для этого приложение входило заново — то есть хранило на
  /// телефоне пароль и посылало его при каждом запуске. Пропуск делает то
  /// же самое и продлевается сам, а пароля на телефоне больше нет.
  ///
  /// Возвращает true, если сервер сказал, что пароль пора сменить: так
  /// узнаёт о сбросе тот, кто уже вошёл, — до этого о сбросе знал один
  /// экран входа.
  Future<bool> _refreshProfile(SecureStorageHelper secure) async {
    try {
      final r = await http
          .get(Uri.parse('${AppValues.baseUrl}/api/me'),
              headers: await authHeaders())
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return false;
      final b = jsonDecode(r.body) as Map<String, dynamic>;
      if (b['message'] != 'Success') return false;
      await secure.saveProfile(
        fullName: (b['full_name'] as String?) ?? '',
        job: (b['job'] as String?) ?? '',
        employeeId: (b['employee_id'] as String?) ?? '',
      );
      return b['must_change_password'] == true;
    } catch (_) {
      // Без связи работаем на сохранённом: код и пропуск лежат на телефоне.
      return false;
    }
  }
}
