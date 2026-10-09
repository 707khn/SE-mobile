import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/screens/directory_screen.dart';
import 'package:se_mobile/screens/home_screen.dart';
import 'package:se_mobile/screens/leave_screen.dart';
import 'package:se_mobile/screens/main_screen_1.dart';
import 'package:se_mobile/screens/main_screen_2.dart';
import 'package:se_mobile/screens/menu_screen.dart';
import 'package:se_mobile/screens/news_screen.dart';
import 'package:se_mobile/screens/payslip_screen.dart';
import 'package:se_mobile/screens/pin_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Крупный шрифт на маленьком телефоне.
///
/// На складе и в столовой шрифт в телефоне часто увеличивают; приложение
/// пускает его до 1,3 (см. main.dart). На 320×568 при этом клавиатура кода
/// наезжала на кружки и уходила за край, строка выбора месяца в листке не
/// помещалась, а заглушка загрузки меню не рисовалась вовсе и писала ошибку
/// в журнал «О программе» при каждом открытии.
///
/// Шрифт — настоящий Roboto из Flutter, которым запущены проверки: тестовый
/// по умолчанию рисует каждую букву квадратом, и ширина текста выходит
/// ложной.
Future<void> _realFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final name in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']) {
    final file = File('$dir/$name');
    if (file.existsSync()) {
      roboto.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
  }
  await roboto.load();
}

/// Один ответ на все запросы, с полями для каждого экрана — длинные ФИО,
/// должности и названия, крупные суммы.
const _name = 'Длиннофамильная-Константинопольская Анастасия Владимировна';
const _job = 'Заместитель главного бухгалтера по налоговому учёту';
const _dept = 'Отдел бухгалтерского и налогового учёта и отчётности (ОБиНУ)';
List<Map<String, dynamic>> _items(String prefix, int n, double amount) => [
  for (var i = 0; i < n; i++) {'name': '$prefix: доплата за работу во вредных и особо тяжёлых условиях труда №$i', 'amount': amount, 'period': '01-31 Сен 26'}
];
final _body = {
  'message': 'Success',
  'today': '2026-10-09',
  'periods': [{'year': 2026, 'month': 9}, {'year': 2026, 'month': 8}],
  'payslip': {
    'year': 2026, 'month': 9,
    'period': 'сентябрь 2026', 'employee': _name, 'position': _job, 'department': _dept,
    'accruals': _items('Начисление', 6, 12345678.90), 'deductions': _items('Удержание', 5, 1234567.89),
    'paid': [for (var i = 0; i < 3; i++) {'payment_type': 'Перечислено в банк по зарплатному проекту', 'period': '01-30 Сен 26', 'document': 'Ведомость в банк №000012345 от 05.10.2026', 'date': '05.10.2026', 'amount': 9876543.21}],
    'benefits': _items('Вычет', 3, 123456.0), 'reference': _items('Справочно', 4, 98765.43),
    'total_accruals': 98765432.10, 'total_deductions': 12345678.90, 'total_paid': 87654321.09,
    'net_pay': 86419753.20, 'debt_start': -1234567.89, 'debt_end': 7654321.0,
  },
  'access': {'date': '2026-10-09', 'first_in': '07:51', 'last_out': '17:05'},
  'leave': {'remaining_days': 126},
  'menu': {'count': 12, 'dishes': ['Борщ украинский со сметаной и пампушками', 'Плов по-узбекски с бараниной', 'Компот из сухофруктов']},
  'leaves': {
    'employee': _name,
    'balances': [for (final t in ['Ежегодный оплачиваемый трудовой отпуск', 'Дополнительный отпуск за вредные условия труда', 'Экологический отпуск']) {'type': t, 'total_days': 124, 'used_days': 110, 'remaining_days': 114}],
    'history': [for (var i = 0; i < 4; i++) {'type': 'Ежегодный оплачиваемый трудовой отпуск', 'start_date': '2026-0${i + 1}-01', 'end_date': '2026-0${i + 1}-28', 'days': 28, 'status': 'Утверждён и оплачен'}],
  },
  'entries': [for (var i = 0; i < 8; i++) {'name': _name, 'position': _job, 'department': _dept, 'extension': '1234, 5678', 'mobile': '+7 (777) 123-45-67, +7 (705) 765-43-21', 'email': 'anastasia.dlinnofamilnaya-konstantinopolskaya@se-btrz.com'}],
  'items': [for (var i = 0; i < 8; i++) {'id': i, 'category': 'Первые блюда и горячие супы', 'name': 'Борщ украинский со сметаной, пампушками и чесночным соусом', 'price': 123456.0, 'portion': '350/50/30 г', 'title': 'Открытие нового цеха металлоконструкций и торжественное вручение наград ветеранам предприятия', 'summary': 'Длинный текст новости ' * 10, 'source': 'site', 'url': 'https://se-btrz.com/news/x', 'image_url': '', 'author': _name, 'published_at': '2026-10-08T10:00:00+00:00'}],
  'report': [for (var d = 1; d <= 9; d++) for (final ev in ['Вход', 'Выход']) {'date': '2026-10-0$d', 'time': ev == 'Вход' ? '07:51' : '17:05', 'event': ev, 'door': 'Турникет №1 главной проходной административного корпуса'}],
  'coverage': {'employee_has_any': true, 'employee_until': '2026-10-09', 'loaded_until': '2026-10-09'},
};

void main() {
  setUpAll(_realFonts);

  final screens = <String, Widget Function()>{
    'создание кода': () => const PinScreen(mode: PinMode.create),
    'ввод кода': () => const PinScreen(mode: PinMode.unlock),
    'меню': () => const MenuScreen(),
    'листок': () => const PayslipPage(),
  };

  for (final lang in ['ru', 'kk']) {
    for (final entry in screens.entries) {
      testWidgets('${entry.key} ($lang): 320×568, шрифт 1,3', (tester) async {
        SharedPreferences.setMockInitialValues({});
        FlutterSecureStorage.setMockInitialValues({'employeeId': 'TEST0001'});
        await tester.runAsync(Lang.initDates);
        tester.view.physicalSize = const Size(320, 568) * tester.view.devicePixelRatio;
        addTearDown(tester.view.resetPhysicalSize);

        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError =
            (d) => errors.add(d.exceptionAsString().split('\n').first);
        await tester.pumpWidget(GetMaterialApp(
          translations: LocaleString(),
          locale: Locale(lang),
          theme: ThemeData(fontFamily: 'Roboto'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: entry.value(),
        ));
        // Первый кадр — с заглушкой загрузки, дальше — ответ (здесь ошибка
        // связи: сервера в проверках нет).
        for (var i = 0; i < 4; i++) {
          await tester.runAsync(
              () => Future.delayed(const Duration(milliseconds: 80)));
          await tester.pump(const Duration(milliseconds: 300));
        }
        FlutterError.onError = previous;
        expect(errors, isEmpty);
      });
    }
  }

  // Те же экраны с данными: пустой экран переполнениям не подвержен. Так
  // нашлись кнопки Excel/CSV в проходах, которые не помещались и при
  // обычном шрифте, значок статуса отпуска, съедавший всю строку, и
  // «таблетки» справочника шире экрана.
  final filled = <String, Widget Function()>{
    'листок': () => const PayslipPage(),
    'отпуск': () => const LeavePage(),
    'справочник': () => const DirectoryScreen(),
    'новости': () => const NewsScreen(),
    'меню': () => const MenuScreen(),
    'главный': () => HomeScreen(fullName: _name, job: _job, onNavigate: (_) {}),
    'проходы': () => const MainPage1(fullName: _name, job: _job),
    'отчёт начальника': () => const MainPage2(fullName: _name, job: 'Начальник отдела'),
  };
  for (final lang in ['ru', 'kk']) {
    for (final scale in [1.0, 1.3]) {
      for (final entry in filled.entries) {
        testWidgets('${entry.key} с данными ($lang, шрифт $scale): 320×568',
            (tester) async {
          SharedPreferences.setMockInitialValues({});
          FlutterSecureStorage.setMockInitialValues(
              {'employeeId': 'TEST0001', 'fullName': _name, 'job': _job});
          await tester.runAsync(Lang.initDates);
          tester.view.physicalSize =
              const Size(320, 568) * tester.view.devicePixelRatio;
          addTearDown(tester.view.resetPhysicalSize);

          final errors = <String>[];
          final previous = FlutterError.onError;
          FlutterError.onError =
              (d) => errors.add(d.exceptionAsString().split('\n').first);
          await HttpOverrides.runWithHttpOverrides(() async {
            await tester.pumpWidget(GetMaterialApp(
              translations: LocaleString(),
              locale: Locale(lang),
              theme: ThemeData(fontFamily: 'Roboto'),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: entry.value(),
            ));
            for (var i = 0; i < 6; i++) {
              await tester.runAsync(
                  () => Future.delayed(const Duration(milliseconds: 80)));
              await tester.pump(const Duration(milliseconds: 300));
            }
          },
              FakeServer(200, jsonEncode(_body),
                  contentType: 'application/json; charset=utf-8'));
          FlutterError.onError = previous;
          expect(errors, isEmpty);
        });
      }
    }
  }
}
