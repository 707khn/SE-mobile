import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/hr_request.dart';
import 'package:se_mobile/screens/hr_queue_screen.dart';
import 'package:se_mobile/screens/hr_requests_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';
import 'package:se_mobile/utils/role_helper.dart';
import 'package:se_mobile/widgets/load_error_view.dart';

import 'support/fake_server.dart';

/// Заявки в отдел кадров: у сотрудника и в очереди кадров.
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester, FakeServer server, Widget home) async {
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: home,
      ));
      await settle(tester);
    }, server);
  }

  Map<String, dynamic> item(int id, String status, {String note = ''}) => {
        'id': id,
        'kind': 'employment',
        'details': 'в банк',
        'copies': 1,
        'status': status,
        'hr_note': note,
        'created_at': '2026-10-22T05:00:00+00:00',
        'employee': {
          'employee_id': '0000000001',
          'full_name': 'Иванов Иван Иванович',
          'job_title': 'Слесарь',
          'department': 'Цех',
        },
      };

  test('разбор ответа и шаги кадров', () {
    final r = HrRequest.fromJson({
      'id': 7,
      'kind': 'vacation',
      'leave_type': 'Экологический отпуск',
      'start_date': '2026-11-02',
      'end_date': '2026-11-15',
      'status': 'new',
    });
    expect(r.vacationDays, 14);
    expect(r.canCancel, isTrue);
    expect(r.nextSteps, ['accepted', 'ready', 'rejected']);
    expect(HrRequest.fromJson(item(1, 'ready')).nextSteps, ['done', 'rejected']);
    expect(HrRequest.fromJson(item(1, 'done')).nextSteps, isEmpty);
    expect(HrRequest.fromJson(item(1, 'accepted')).canCancel, isFalse);
  });

  test('кто разбирает заявки', () {
    expect(canProcessHr('Специалист по кадрам'), isTrue);
    expect(canProcessHr('Начальник отдела кадров'), isTrue);
    expect(canProcessHr('Администратор системы'), isTrue);
    expect(canProcessHr('Слесарь'), isFalse);
  });

  test('надписи для всех состояний и видов есть в обоих языках', () {
    final keys = LocaleString().keys;
    for (final lang in [Lang.ru, Lang.kk]) {
      for (final s in ['new', 'accepted', 'ready', 'done', 'rejected', 'cancelled']) {
        expect(keys[lang]!.containsKey(hrStatusKey(s)), isTrue, reason: '$lang $s');
      }
      for (final k in ['employment', 'income', 'vacation']) {
        expect(keys[lang]!.containsKey(hrKindKey(k)), isTrue, reason: '$lang $k');
      }
      for (final s in ['accepted', 'ready', 'done', 'rejected']) {
        expect(keys[lang]!.containsKey('hr_step_$s'), isTrue, reason: '$lang $s');
      }
    }
  });

  testWidgets('сотрудник видит, что справка готова и где забрать',
      (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'items': [item(3, 'ready', note: 'Заберите в каб. 12')]
          })
        ));
    await open(tester, server, const HrRequestsScreen());
    expect(find.text('hr_status_ready'.tr), findsOneWidget);
    expect(find.text('Заберите в каб. 12'), findsOneWidget);
    // Готовую уже не отозвать.
    expect(find.text('hr_cancel'.tr), findsNothing);
  });

  testWidgets('заявки не загрузились — ошибка, а не «заявок нет»',
      (tester) async {
    await open(tester, FakeServer(502, 'Bad Gateway'), const HrRequestsScreen());
    expect(find.byType(LoadErrorView), findsOneWidget);
    expect(find.text('hr_empty'.tr), findsNothing);
  });

  testWidgets('кадры: отказ без причины не отправить', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'GET'
        ? (200, jsonEncode({'items': [item(5, 'new')], 'counts': {'new': 1}}))
        : (200, jsonEncode({'item': item(5, 'rejected', note: 'x')})));
    await open(tester, server, const HrQueueScreen());
    expect(find.text('Иванов Иван Иванович'), findsOneWidget);
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.text('hr_step_rejected'.tr));
      await settle(tester);
      final button = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'hr_step_rejected'.tr));
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'Нужен паспорт');
      await tester.pump();
      await tester.tap(button);
      await settle(tester);
    }, server);
    final sent = server.requests.where((b) => b.contains('rejected')).toList();
    expect(sent, hasLength(1));
    expect(jsonDecode(sent.single)['note'], 'Нужен паспорт');
  });
}
