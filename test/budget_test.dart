import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/budget_request.dart';
import 'package:se_mobile/screens/budget_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/role_helper.dart';

import 'support/fake_server.dart';

/// План-факт бюджета: свои статьи у начальника, все — у руководства.
void main() {
  const it = 'Отдел информационных технологий и связи (ОИТиС)';
  const stock = 'Служба учета ТМЦ';

  Map<String, dynamic> report({bool all = false, String department = it}) => {
        'message': 'Success',
        'all': all,
        'year': 2030,
        'years': [2030, 2029],
        'departments': [
          {'key': 'it', 'name': it},
          if (all) {'key': 'stock', 'name': stock},
        ],
        'department': department,
        'department_key': department == it ? 'it' : 'stock',
        'months': [2, 3],
        'as_of': '2030-04-01T05:00:00Z',
        'plan': 290000,
        'fact': 280000.5,
        'articles': [
          {
            'article': 'Материалы',
            'plan': 190000,
            'fact': 200000,
            'months': [
              {'month': 2, 'plan': 90000, 'fact': 80000},
              {'month': 3, 'plan': 100000, 'fact': 120000},
            ],
          },
          {
            'article': 'Услуги связи',
            'plan': 100000,
            'fact': 80000.5,
            'months': const [],
          },
        ],
      };

  test('суммы и перерасход', () {
    expect(budgetMoney(1234567.4), '1 234 567');
    expect(budgetMoney(-10000), '−10 000');
    expect(budgetMoney(999), '999');
    final parsed = BudgetReport.fromJson(report());
    expect(parsed.articles.first.over, isTrue);
    expect(parsed.articles.last.over, isFalse);
    expect(parsed.months, [2, 3]);
  });

  test('кому пункт в меню', () {
    expect(usesBudget('Начальник ОИТиС'), isTrue);
    expect(usesBudget('Заведующий хозяйством'), isTrue);
    expect(usesBudget('Начальник ПЭО'), isTrue);
    expect(usesBudget('Инженер-программист'), isFalse);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('bg_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('bg_')).toSet();
    expect(kk, ru);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester
          .runAsync(() => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: home,
    ));
    await settle(tester);
  }

  testWidgets('начальник видит свои статьи по месяцам', (tester) async {
    final urls = <Uri>[];
    final server = FakeServer.routed((method, url, body) {
      urls.add(url);
      return (200, jsonEncode(report()));
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const BudgetScreen());
      expect(find.byKey(const Key('bg_department')), findsNothing);
      expect(find.text('2030 год · Месяцы: Февраль, Март'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('bg_total_left'))).data,
          '10 000');
      expect(find.text('Факт 200 000 из 190 000 · 105%'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('bg_left_0'))).data,
          '−10 000');
      await tester.tap(find.byKey(const Key('bg_article_0')));
      await tester.pumpAndSettle();
      expect(find.text('план 100 000 · факт 120 000'), findsOneWidget);

      await tester.tap(find.byKey(const Key('bg_years')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bg_year_2029')));
      await settle(tester);
    }, server);
    expect(urls.last.queryParameters, {'year': '2029'});
  });

  testWidgets('руководство выбирает подразделение', (tester) async {
    final urls = <Uri>[];
    final server = FakeServer.routed((method, url, body) {
      urls.add(url);
      return (
        200,
        jsonEncode(report(
            all: true,
            department:
                url.queryParameters['department'] == 'stock' ? stock : it))
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const BudgetScreen());
      await tester.tap(find.byKey(const Key('bg_department')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(stock).last);
      await settle(tester);
    }, server);
    expect(urls.last.queryParameters, {'year': '2030', 'department': 'stock'});
  });
}
