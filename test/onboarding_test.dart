import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/onboarding_request.dart';
import 'package:se_mobile/screens/onboarding_detail_screen.dart';
import 'package:se_mobile/screens/onboarding_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Первые дни новичка: план, отметки служб, заведение кадрами.
void main() {
  Map<String, dynamic> person(String id, String name) =>
      {'id': id, 'name': name, 'job_title': 'Инженер-технолог'};

  Map<String, dynamic> plan(int id,
          {Set<String> done = const {},
          Set<String> canMark = const {},
          bool mine = false,
          bool manage = false,
          String status = 'active'}) =>
      {
        'id': id,
        'employee': person('0000001816', 'Новичков Иван'),
        'mentor': person('0000001674', 'Наставников Пётр'),
        'start_date': '2030-01-20',
        'note': '',
        'status': status,
        'steps': [
          for (final s in onboardingSteps)
            {
              'step': s,
              'done': done.contains(s),
              'done_at': done.contains(s) ? '2030-01-20T05:00:00Z' : null,
              'done_by': done.contains(s)
                  ? person('0000001965', 'Программистов Олег')
                  : null,
              'note':
                  s == 'account' && done.contains(s) ? 'Логин в письме' : '',
              'can_mark': canMark.contains(s),
            }
        ],
        'done_count': done.length,
        'total': onboardingSteps.length,
        'is_mine': mine,
        'can_manage': manage,
      };

  test('разбор плана', () {
    final p = Onboarding.fromJson(plan(1, done: {'account'}));
    expect(p.steps.map((s) => s.step), onboardingSteps);
    expect(p.doneCount, 1);
    expect(p.steps.first.doneBy!.name, 'Программистов Олег');
    expect(p.mentor!.jobTitle, 'Инженер-технолог');
    expect(onboardingDate(p.startDate), '20.01.2030');
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('ob_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('ob_')).toSet();
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

  testWidgets('новичок видит свой план, пусто — подсказка', (tester) async {
    var withPlan = true;
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'hr': false,
            'mine': withPlan ? plan(1, done: {'account'}, mine: true) : null,
            'items': [],
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const OnboardingScreen());
      expect(find.text('Мой план'), findsOneWidget);
      expect(find.text('Выход на работу: 20.01.2030'), findsOneWidget);
      expect(find.text('Готово 1 из 6'), findsOneWidget);
      expect(find.byKey(const Key('ob_new')), findsNothing);
      withPlan = false;
      await tester.tap(find.byIcon(Icons.refresh));
      await settle(tester);
      expect(find.byKey(const Key('ob_empty')), findsOneWidget);
    }, server);
  });

  testWidgets('служба отмечает свой пункт с пояснением', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': plan(2, done: {'account'})
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item': plan(2, canMark: {'account'})
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const OnboardingDetailScreen(onboardingId: 2));
      expect(find.text('ОИТиС: почта и вход в приложение'), findsOneWidget);
      final pass = tester
          .widget<CheckboxListTile>(find.byKey(const Key('ob_mark_pass')));
      expect(pass.onChanged, isNull);
      await tester.tap(find.byKey(const Key('ob_mark_account')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('field_note')), 'Логин в письме');
      await tester.pump();
      await tester.tap(find.byKey(const Key('fields_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(jsonDecode(server.requests.last), {
      'action': 'step',
      'step': 'account',
      'done': true,
      'note': 'Логин в письме',
    });
    expect(tester.widget<Text>(find.byKey(const Key('ob_progress'))).data,
        'Готово 1 из 6');
    expect(find.textContaining('Логин в письме'), findsOneWidget);
  });

  testWidgets('кадры заводят план: новичок, наставник, пункты', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.path.endsWith('/people')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'people': [
              person('0000001816', 'Новичков Иван'),
              person('0000001674', 'Наставников Пётр'),
            ]
          })
        );
      }
      return (201, jsonEncode({'message': 'Success', 'item': plan(3)}));
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, OnboardingFormScreen(now: DateTime(2030, 1, 20)));
      await tester.tap(find.byKey(const Key('ob_create')));
      await tester.pump();
      expect(find.text('Выберите нового сотрудника'), findsWidgets);
      await tester.tap(find.byKey(const Key('ob_newcomer')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('person_0000001816')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('ob_step_clothing')));
      await tester.tap(find.byKey(const Key('ob_step_mentor')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('ob_create')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(jsonDecode(server.requests.last), {
      'employee_id': '0000001816',
      'start_date': '2030-01-20',
      'steps': ['account', 'pass', 'induction', 'workplace'],
    });
  });
}
