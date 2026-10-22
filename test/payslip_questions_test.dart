import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/payslip_question_request.dart';
import 'package:se_mobile/screens/payslip_question_detail_screen.dart';
import 'package:se_mobile/screens/payslip_questions_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Вопрос по листку: форма со строкой листка, переписка, «Вопрос решён».
void main() {
  Map<String, dynamic> question(int id, String status,
          {bool isAuthor = true, bool canAnswer = false}) =>
      {
        'id': id,
        'year': 2026,
        'month': 9,
        'line': 'Удержания: ИПН — 12 345,00',
        'status': status,
        'author': {'id': '0000002107', 'name': 'Автор Тест'},
        'assignee': null,
        'updated_at': '2026-10-22T05:00:00+00:00',
        'messages': [
          {
            'text': 'Почему ИПН больше?',
            'kind': 'message',
            'at': '2026-10-22T05:00:00Z',
            'author': {'id': '0000002107', 'name': 'Автор Тест'},
            'from_payroll': false
          },
          if (status != 'open')
            {
              'text': 'В сентябре была премия.',
              'kind': 'message',
              'at': '2026-10-22T06:00:00Z',
              'author': {'id': '0000001469', 'name': 'Бухгалтер Тест'},
              'from_payroll': true
            },
        ],
        'is_author': isAuthor,
        'can_answer': canAnswer,
      };

  test('разбор', () {
    final q = PayslipQuestion.fromJson(question(3, 'answered'));
    expect(q.period, DateTime(2026, 9));
    expect(q.messages.last.fromPayroll, isTrue);
    final list = PayslipQuestionList.fromJson(
        {'staff': true, 'open': 2, 'items': [question(1, 'open'), 3]});
    expect(list.items.single.id, 1);
    expect(list.open, 2);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('psq_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('psq_')).toSet();
    expect(kk, ru);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 1800);
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

  testWidgets('вопрос уходит с месяцем и выбранной строкой', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (201, jsonEncode({'message': 'Success', 'item': question(7, 'open')}))
        : (200, jsonEncode({'message': 'Success', 'item': question(7, 'open')})));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(
          tester,
          PayslipAskScreen(month: DateTime(2026, 9), lines: const [
            'Начисления: Оклад — 250 000,00',
            'Удержания: ИПН — 12 345,00',
          ]));
      expect(find.text('Листок за Сентябрь 2026'), findsOneWidget);
      await tester.tap(find.byKey(const Key('psq_send')));
      await tester.pump();
      expect(find.text('Напишите вопрос'), findsOneWidget);

      await tester.tap(find.byKey(const Key('psq_line')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удержания: ИПН — 12 345,00').last);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('psq_text')), 'Почему ИПН больше?');
      await tester.tap(find.byKey(const Key('psq_send')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    final sent = jsonDecode(server.requests.first) as Map<String, dynamic>;
    expect(sent, {
      'year': 2026,
      'month': 9,
      'text': 'Почему ИПН больше?',
      'line': 'Удержания: ИПН — 12 345,00',
    });
    // После отправки — сразу переписка по вопросу.
    expect(find.byType(PayslipQuestionDetailScreen), findsOneWidget);
  });

  testWidgets('автор видит ответ и закрывает вопрос', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (200, jsonEncode({'message': 'Success', 'item': question(4, 'closed')}))
        : (
            200,
            jsonEncode({'message': 'Success', 'item': question(4, 'answered')})
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const PayslipQuestionDetailScreen(questionId: 4));
      expect(find.text('В сентябре была премия.'), findsOneWidget);
      expect(find.textContaining('Расчётная группа'), findsOneWidget);
      await tester.tap(find.byKey(const Key('psq_close')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(sent, {'action': 'close'});
    expect(find.text('Решён'), findsOneWidget);
    expect(find.byKey(const Key('psq_close')), findsNothing);
  });

  testWidgets('чужой бухгалтер не видит поля ответа на закрытом',
      (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'item': question(4, 'closed', isAuthor: false, canAnswer: false)
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const PayslipQuestionDetailScreen(questionId: 4));
    }, server);
    expect(find.byKey(const Key('psq_reply')), findsNothing);
    expect(find.text('Автор Тест'), findsOneWidget);
  });
}
