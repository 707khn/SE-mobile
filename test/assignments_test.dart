import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/assignment_request.dart';
import 'package:se_mobile/screens/assignment_detail_screen.dart';
import 'package:se_mobile/screens/assignment_form_screen.dart';
import 'package:se_mobile/screens/assignments_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Поручения: отчёт исполнителя, приёмка, перенос срока, выдача.
void main() {
  Map<String, dynamic> item(int id, String status,
          {bool author = false,
          bool assignee = false,
          bool overdue = false,
          String? proposed,
          String result = ''}) =>
      {
        'id': id,
        'title': 'Подготовить план на ноябрь',
        'text': 'По всем участкам.',
        'important': true,
        'due_date': '2030-01-20',
        'status': status,
        'overdue': overdue,
        'result': result,
        'proposed_due': proposed,
        'proposed_reason': proposed == null ? '' : 'Жду данные от ОП',
        'author': {'id': '0000000016', 'name': 'Начальник Тест Тестович'},
        'assignee': {'id': '0000001445', 'name': 'Исполнитель Тест Тестович'},
        'updated_at': '2030-01-15T05:00:00Z',
        'events': [
          {
            'action': 'created',
            'at': '2030-01-15T05:00:00Z',
            'due': '2030-01-20',
            'actor': {'id': '0000000016', 'name': 'Начальник Тест Тестович'}
          }
        ],
        'is_author': author,
        'is_assignee': assignee,
        'can_remind': author && (status == 'new' || status == 'in_progress'),
      };

  test('разбор', () {
    final a =
        Assignment.fromJson(item(3, 'in_progress', proposed: '2030-01-25'));
    expect(a.dueDate, DateTime(2030, 1, 20));
    expect(a.proposedDue, DateTime(2030, 1, 25));
    expect(a.isOpen, isTrue);
    expect(a.events.single.due, DateTime(2030, 1, 20));
    final list = AssignmentList.fromJson({
      'can_assign': true,
      'counts': {'mine_open': 2, 'given_done': 1},
      'items': [item(1, 'new'), 5],
    });
    expect(list.items.single.id, 1);
    expect(list.counts.mineOpen, 2);
    expect(list.counts.givenDone, 1);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('asg_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('asg_')).toSet();
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

  testWidgets('исполнитель отчитывается: без отчёта не уходит', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item':
                  item(4, 'done', assignee: true, result: 'План в общей папке.')
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item': item(4, 'in_progress', assignee: true, overdue: true)
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const AssignmentDetailScreen(assignmentId: 4));
      expect(find.text('Просрочено · до 20.01'), findsOneWidget);
      expect(find.text('Поручил: Начальник Тест Тестович'), findsOneWidget);
      expect(find.byKey(const Key('asg_accept')), findsNothing);
      expect(find.byKey(const Key('asg_close')), findsNothing);
      await tester.tap(find.byKey(const Key('asg_done')));
      await tester.pumpAndSettle();
      final ok = find.byKey(const Key('prompt_ok'));
      expect(tester.widget<TextButton>(ok).onPressed, isNull);
      await tester.enterText(
          find.byKey(const Key('prompt_text')), 'План в общей папке.');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(jsonDecode(server.requests.last),
        {'action': 'done', 'comment': 'План в общей папке.'});
    expect(find.text('Отчёт: План в общей папке.'), findsOneWidget);
    expect(find.byKey(const Key('asg_done')), findsNothing);
  });

  testWidgets('поручивший видит просьбу о переносе и соглашается',
      (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': item(4, 'in_progress', author: true)
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item':
                  item(4, 'in_progress', author: true, proposed: '2030-01-25')
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const AssignmentDetailScreen(assignmentId: 4));
      expect(find.text('Просит перенести срок на 25.01.2030: Жду данные от ОП'),
          findsOneWidget);
      expect(find.byKey(const Key('asg_extend')), findsNothing);
      expect(find.byKey(const Key('asg_remind')), findsOneWidget);
      await tester.tap(find.byKey(const Key('asg_extend_ok')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.last), {'action': 'extend_ok'});
    expect(find.byKey(const Key('asg_extend_ok')), findsNothing);
  });

  testWidgets('поручение уходит нескольким исполнителям', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.path.endsWith('/people')) {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'people': [
              {
                'id': '0000001445',
                'name': 'Исполнитель Тест Тестович',
                'job_title': 'Менеджер',
                'department': 'ПЭО'
              },
              {
                'id': '0000001864',
                'name': 'Второй Тест Тестович',
                'job_title': 'Менеджер',
                'department': 'ПЭО'
              },
            ]
          })
        );
      }
      return (
        201,
        jsonEncode({
          'message': 'Success',
          'items': [item(7, 'new', author: true), item(8, 'new', author: true)]
        })
      );
    });
    List<Assignment>? created;
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(
          tester,
          Builder(
              builder: (context) => Scaffold(
                    body: TextButton(
                        key: const Key('open'),
                        onPressed: () async => created =
                            await Get.to(() => const AssignmentFormScreen()),
                        child: const Text('open')),
                  )));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('asg_title')), 'Подготовить план на ноябрь');
      await tester.tap(find.byKey(const Key('asg_send')));
      await tester.pump();
      expect(find.text('Неверный срок'), findsOneWidget);

      await tester.tap(find.byKey(const Key('asg_due')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      for (final id in ['0000001445', '0000001864']) {
        await tester.tap(find.byKey(const Key('asg_add_assignee')));
        await settle(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('asg_found_$id')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const Key('asg_important')));
      await tester.tap(find.byKey(const Key('asg_send')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    final sent = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(sent['title'], 'Подготовить план на ноябрь');
    expect(sent['assignee_ids'], ['0000001445', '0000001864']);
    expect(sent['important'], isTrue);
    expect(sent['due_date'], isNotNull);
    expect(created?.length, 2);
  });

  testWidgets('без права поручать нет вкладки и кнопки', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'can_assign': false,
            'counts': {'mine_open': 1},
            'items': url.query.contains('given')
                ? []
                : [item(4, 'new', assignee: true)]
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const AssignmentsScreen());
    }, server);
    expect(find.text('Подготовить план на ноябрь'), findsOneWidget);
    expect(find.byKey(const Key('asg_new')), findsNothing);
    expect(find.text('Я поручил'), findsNothing);
  });
}
