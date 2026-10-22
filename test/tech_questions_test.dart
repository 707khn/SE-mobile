import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/tech_question_request.dart';
import 'package:se_mobile/screens/tech_question_detail_screen.dart';
import 'package:se_mobile/screens/tech_question_form_screen.dart';
import 'package:se_mobile/screens/tech_questions_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Вопрос в ТО: форма, решение, уточнение, история по изделию.
void main() {
  Map<String, dynamic> question(int id, String status,
          {bool author = true, bool canAnswer = false, String decision = ''}) =>
      {
        'id': id,
        'kind': 'drawing',
        'product': 'Корпус 7.312',
        'document': 'ЧТ 7.312.001',
        'operation': '015',
        'text': 'Размер 45 на чертеже, по калибру 44,8',
        'urgent': false,
        'status': status,
        'decision': decision,
        'author': {'id': '0000000082', 'name': 'Мастер Тест'},
        'assignee': null,
        'created_at': '2030-01-15T05:00:00Z',
        'events': [
          {
            'action': 'created',
            'at': '2030-01-15T05:00:00Z',
            'actor': {'id': '0000000082', 'name': 'Мастер Тест'}
          }
        ],
        'is_author': author,
        'can_answer': canAnswer,
      };

  test('разбор', () {
    final q = TechQuestion.fromJson(question(1, 'answered', decision: '44,8'));
    expect(q.where, 'ЧТ 7.312.001, оп. 015');
    expect(q.decision, '44,8');
    final list = TechQuestionList.fromJson({
      'staff': true,
      'history': true,
      'waiting': 3,
      'items': [question(1, 'new'), 2]
    });
    expect(list.items.single.id, 1);
    expect(list.waiting, 3);
    expect(list.history, isTrue);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('tq_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('tq_')).toSet();
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

  testWidgets('вопрос уходит с изделием, чертежом и операцией', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (201, jsonEncode({'message': 'Success', 'item': question(7, 'new')}))
        : (200, jsonEncode({'message': 'Success', 'products': []})));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const TechQuestionFormScreen());
      await tester.tap(find.byKey(const Key('tq_send')));
      await tester.pump();
      expect(find.text('Укажите изделие'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tq_kind_process')));
      await tester.enterText(
          find.byKey(const Key('tq_product')), 'Корпус 7.312');
      await tester.enterText(find.byKey(const Key('tq_document')), 'ТП 7.312');
      await tester.enterText(find.byKey(const Key('tq_operation')), '015');
      await tester.enterText(
          find.byKey(const Key('tq_text')), 'Нет режима для новой фрезы');
      await tester.tap(find.byKey(const Key('tq_urgent')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tq_send')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(sent, {
      'kind': 'process',
      'product': 'Корпус 7.312',
      'text': 'Нет режима для новой фрезы',
      'document': 'ТП 7.312',
      'operation': '015',
      'urgent': true,
    });
  });

  testWidgets('конструктор даёт решение', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': question(4, 'answered',
                  author: false, canAnswer: true, decision: 'Верный 44,8')
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item': question(4, 'in_work', author: false, canAnswer: true)
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const TechQuestionDetailScreen(questionId: 4));
      expect(find.text('Мастер Тест'), findsOneWidget);
      expect(find.byKey(const Key('tq_take')), findsNothing);
      expect(find.byKey(const Key('tq_close')), findsNothing);
      await tester.tap(find.byKey(const Key('tq_answer')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('prompt_text')), 'Верный 44,8');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(jsonDecode(server.requests.last),
        {'action': 'answer', 'text': 'Верный 44,8'});
    expect(find.byKey(const Key('tq_decision')), findsOneWidget);
  });

  testWidgets('автор принимает решение', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': question(4, 'closed', decision: 'Верный 44,8')
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item': question(4, 'answered', decision: 'Верный 44,8')
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const TechQuestionDetailScreen(questionId: 4));
      expect(find.byKey(const Key('tq_clarify')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tq_close')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.last), {'action': 'close'});
    expect(find.text('Закрыт'), findsOneWidget);
    expect(find.byKey(const Key('tq_comment')), findsNothing);
  });

  testWidgets('мастер находит прежнее решение по изделию', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.queryParameters['product'] != null) {
        expect(url.queryParameters['product'], 'корпус');
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'items': [
              question(2, 'closed', author: false, decision: 'Верный 44,8')
            ]
          })
        );
      }
      return (
        200,
        jsonEncode({'message': 'Success', 'history': true, 'items': []})
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const TechQuestionsScreen());
      await tester.tap(find.text('По изделию'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('tq_search')), 'корпус');
      await tester.tap(find.byKey(const Key('tq_search_go')));
      await settle(tester);
    }, server);
    expect(find.text('Решение ТО: Верный 44,8'), findsOneWidget);
  });
}
