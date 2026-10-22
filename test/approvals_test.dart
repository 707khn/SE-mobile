import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/approval_request.dart';
import 'package:se_mobile/screens/approval_detail_screen.dart';
import 'package:se_mobile/screens/approval_form_screen.dart';
import 'package:se_mobile/screens/approvals_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Лист согласования: маршрут, «на подпись», согласование с замечаниями.
void main() {
  Map<String, dynamic> person(String id, String name, [String title = '']) =>
      {'id': id, 'name': name, 'title': title, 'department': ''};

  final dmto = person('0000002198', 'Руководитель Тест', 'Руководитель ДМТО');
  final legal =
      person('0000000450', 'Юрист Тест', 'Начальник юридического отдела');
  final peo = person('0000000016', 'Экономист Тест', 'Начальник ПЭО');
  final acc = person('0000001298', 'Бухгалтер Тест', 'Главный бухгалтер');

  Map<String, dynamic> item(int id, String status,
          {bool myTurn = false,
          bool isAuthor = false,
          bool canRemind = false,
          Duration waited = const Duration(hours: 3)}) =>
      {
        'id': id,
        'kind': 'contract',
        'title': 'Договор поставки',
        'doc_number': 'Д-245/26',
        'counterparty': 'ТОО «Металл»',
        'amount': '12 500 000 тг',
        'summary': 'Лист 3 мм, 20 т',
        'status': status,
        'author': person('0000001582', 'Автор Тест'),
        'current': status == 'on_route' ? legal : null,
        'step': 1,
        'step_since':
            DateTime.now().toUtc().subtract(waited).toIso8601String(),
        'created_at': '2026-10-20T05:00:00+00:00',
        'steps': [
          {'position': 0, 'person': dmto, 'decision': 'approved', 'comment': ''},
          {
            'position': 1,
            'person': legal,
            'decision': status == 'approved' ? 'approved' : 'pending',
            'comment': status == 'approved' ? 'Пункт 5.2' : '',
          },
        ],
        'events': [],
        'my_turn': myTurn,
        'is_author': isAuthor,
        'can_remind': canRemind,
      };

  test('разбор, «завис» после двух суток', () {
    final a = Approval.fromJson(item(3, 'on_route', waited: const Duration(days: 3)));
    expect(a.current!.short, 'Юрист Т.');
    expect(a.approvedCount, 1);
    expect(a.isStale(DateTime.now()), isTrue);
    expect(Approval.fromJson(item(4, 'on_route')).isStale(DateTime.now()),
        isFalse);
    final list = ApprovalList.fromJson({'todo': 2, 'items': [item(1, 'on_route'), 5]});
    expect(list.items.single.id, 1);
    expect(list.todo, 2);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('appr_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('appr_')).toSet();
    expect(kk, ru);
    for (final s in ['on_route', 'approved', 'returned', 'cancelled']) {
      expect(ru, contains('appr_status_$s'));
    }
    for (final a in ['created', 'approve', 'return', 'resubmit', 'cancel', 'remind', 'comment']) {
      expect(ru, contains('appr_ev_$a'));
    }
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, FakeServer server, Widget home) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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

  testWidgets('«На подпись» — только мои, со счётчиком', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'todo': 1,
            'items': [
              {...item(5, 'on_route', myTurn: true), 'title': 'Мой черёд'},
              {...item(6, 'approved'), 'title': 'Уже прошёл'},
            ],
          })
        ));
    await pump(tester, server, const ApprovalsScreen());
    expect(find.text('На подпись (1)'), findsOneWidget);
    expect(find.text('№5 · Мой черёд'), findsOneWidget);
    expect(find.text('№6 · Уже прошёл'), findsNothing);
    await tester.tap(find.text('Все'));
    await tester.pumpAndSettle();
    expect(find.text('№6 · Уже прошёл'), findsOneWidget);
  });

  testWidgets('форма: обычный маршрут, правка и отправка', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.path.endsWith('/route')) {
        return (200, jsonEncode({'steps': [dmto, legal, peo]}));
      }
      if (url.path.endsWith('/people')) {
        return (200, jsonEncode({'people': [acc]}));
      }
      return (
        201,
        jsonEncode({'message': 'Success', 'item': item(9, 'on_route')})
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, server, const ApprovalFormScreen());
      expect(find.byKey(const Key('appr_step_0000000450')), findsOneWidget);

      await tester.tap(find.byKey(const Key('appr_send')));
      await tester.pump();
      expect(find.text('Напишите название'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('appr_title')), 'Договор');
      await tester.enterText(find.byKey(const Key('appr_summary')), 'Суть');
      await tester.enterText(find.byKey(const Key('appr_amount')), '1 000 тг');
      await tester.tap(find.byKey(const Key('appr_remove_0000000016')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('appr_add_step')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const Key('appr_search')), 'главный бухгалтер');
      await tester.pump(const Duration(milliseconds: 350));
      await settle(tester);
      await tester.tap(find.byKey(const Key('appr_found_0000001298')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('appr_send')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(sent, {
      'kind': 'contract',
      'title': 'Договор',
      'summary': 'Суть',
      'route': ['0000002198', '0000000450', '0000001298'],
      'amount': '1 000 тг',
    });
  });

  testWidgets('согласующий: согласовать с замечаниями', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        return (
          200,
          jsonEncode({'message': 'Success', 'item': item(4, 'approved')})
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'item': item(4, 'on_route', myTurn: true)
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, server, const ApprovalDetailScreen(approvalId: 4));
      expect(find.textContaining('лежит 3 ч'), findsOneWidget);
      expect(find.byKey(const Key('appr_remind')), findsNothing);

      // Вернуть без причины нельзя.
      await tester.tap(find.byKey(const Key('appr_return')));
      await tester.pumpAndSettle();
      expect(
          tester
              .widget<TextButton>(find.byKey(const Key('prompt_ok')))
              .onPressed,
          isNull);
      await tester.tap(find.text('Отмена').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('appr_approve')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('prompt_text')), 'Пункт 5.2');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt_ok')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(sent, {'action': 'approve', 'comment': 'Пункт 5.2'});
    expect(find.text('Согласован'), findsOneWidget);
    expect(find.textContaining('С замечаниями'), findsOneWidget);
  });

  testWidgets('автор: «Напомнить» гаснет, пока рано', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'item': item(4, 'on_route', isAuthor: true, canRemind: false)
          })
        ));
    await pump(tester, server, const ApprovalDetailScreen(approvalId: 4));
    final remind =
        tester.widget<ButtonStyleButton>(find.byKey(const Key('appr_remind')));
    expect(remind.onPressed, isNull);
    expect(find.byKey(const Key('appr_approve')), findsNothing);
    expect(find.byKey(const Key('appr_cancel')), findsOneWidget);
  });
}
