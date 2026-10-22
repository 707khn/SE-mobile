import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/order_request.dart';
import 'package:se_mobile/screens/order_detail_screen.dart';
import 'package:se_mobile/screens/order_form_screen.dart';
import 'package:se_mobile/screens/order_report_screen.dart';
import 'package:se_mobile/screens/orders_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Ознакомление с приказами: «Ознакомлен», отчёт, рассылка.
void main() {
  Map<String, dynamic> order(int id,
          {String? ackedAt,
          bool publisher = false,
          bool canReport = false,
          bool canRemind = false}) =>
      {
        'id': id,
        'kind': 'order',
        'number': '45-П',
        'doc_date': '2026-10-20',
        'title': 'О режиме работы в праздничные дни',
        'link': '',
        'departments': ['Планово-экономический отдел (ПЭО)'],
        'due_date': '2030-01-01',
        'published_at': '2026-10-22T05:00:00+00:00',
        'acked_at': ackedAt,
        'withdrawn': false,
        if (publisher) 'total': 5,
        if (publisher) 'acked': 2,
        'text': 'Приказываю: установить режим работы.',
        'addressed': true,
        'can_report': canReport,
        'can_remind': canRemind,
        'can_withdraw': publisher,
      };

  test('разбор', () {
    final o = OrderDoc.fromJson(order(3, publisher: true));
    expect(o.docDate, DateTime(2026, 10, 20));
    expect(o.total, 5);
    expect(o.isAcked, isFalse);
    expect(o.overdue(DateTime(2030, 1, 2)), isTrue);
    expect(o.overdue(DateTime(2030, 1, 1)), isFalse);
    final list = OrderList.fromJson({
      'publisher': true,
      'pending': 1,
      'items': [order(1), 'x']
    });
    expect(list.items.single.id, 1);
    expect(list.pending, 1);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('ord_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('ord_')).toSet();
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

  testWidgets('сотрудник ставит отметку «Ознакомлен»', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': order(4, ackedAt: '2026-10-22T06:30:00Z')
            })
          )
        : (200, jsonEncode({'message': 'Success', 'item': order(4)})));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const OrderDetailScreen(orderId: 4));
      expect(find.text('Приказ №45-П от 20.10.2026'), findsOneWidget);
      expect(find.text('Приказываю: установить режим работы.'), findsOneWidget);
      expect(find.byKey(const Key('ord_report')), findsNothing);
      await tester.tap(find.byKey(const Key('ord_ack')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.last), {'action': 'ack'});
    expect(find.byKey(const Key('ord_ack')), findsNothing);
    expect(find.byKey(const Key('ord_acked')), findsOneWidget);
  });

  testWidgets('издающий напоминает и видит счётчик', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (200, jsonEncode({'message': 'Success', 'reminded': 3}))
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item':
                  order(4, publisher: true, canReport: true, canRemind: true)
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const OrderDetailScreen(orderId: 4));
      expect(find.text('Ознакомлены 2 из 5'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ord_remind')));
      await settle(tester);
    }, server);
    expect(server.requests.contains(jsonEncode({'action': 'remind'})), isTrue);
    expect(find.text('Напоминание ушло: 3 чел.'), findsOneWidget);
  });

  testWidgets('в отчёте сначала только неознакомленные', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'total': 2,
            'acked': 1,
            'people': [
              {'id': '1', 'name': 'Нет Отметки', 'department': 'ПЭО'},
              {
                'id': '2',
                'name': 'Уже Ознакомлен',
                'department': 'ПЭО',
                'acked_at': '2026-10-22T06:00:00Z'
              },
            ]
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const OrderReportScreen(orderId: 4));
    }, server);
    expect(find.text('Ознакомлены 1 из 2'), findsOneWidget);
    expect(find.text('Нет Отметки'), findsOneWidget);
    expect(find.text('Уже Ознакомлен'), findsNothing);
    await tester.tap(find.byKey(const Key('ord_only_pending')));
    await tester.pump();
    expect(find.text('Уже Ознакомлен'), findsOneWidget);
  });

  testWidgets('рассылка уходит с видом, номером и текстом', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          201,
          jsonEncode({'message': 'Success', 'item': order(9, publisher: true)})
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const OrderFormScreen());
      await tester.tap(find.byKey(const Key('ord_send')));
      await tester.pump();
      expect(find.text('Напишите название'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ord_kind_instruction')));
      await tester.enterText(find.byKey(const Key('ord_number')), '7');
      await tester.enterText(
          find.byKey(const Key('ord_title')), 'По охране труда');
      await tester.enterText(find.byKey(const Key('ord_text')), 'Текст.');
      await tester.enterText(find.byKey(const Key('ord_link')), 'ftp://x');
      await tester.tap(find.byKey(const Key('ord_send')));
      await tester.pump();
      expect(find.text('Ссылка должна начинаться с https://'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('ord_link')), '');
      await tester.tap(find.byKey(const Key('ord_send')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.single) as Map<String, dynamic>;
    expect(sent['kind'], 'instruction');
    expect(sent['number'], '7');
    expect(sent['title'], 'По охране труда');
    expect(sent['text'], 'Текст.');
    expect(sent['departments'], isEmpty);
    expect(sent.containsKey('link'), isFalse);
    expect(sent['doc_date'], isNotNull);
  });

  testWidgets('у делопроизводителя третья вкладка и кнопка рассылки',
      (tester) async {
    final server =
        FakeServer.routed((method, url, body) => url.query.contains('scope')
            ? (
                200,
                jsonEncode({
                  'message': 'Success',
                  'publisher': true,
                  'items': [order(5, publisher: true)]
                })
              )
            : (
                200,
                jsonEncode({
                  'message': 'Success',
                  'publisher': true,
                  'pending': 1,
                  'items': [order(5)]
                })
              ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const OrdersScreen());
    }, server);
    expect(find.text('К ознакомлению (1)'), findsOneWidget);
    expect(find.text('Разосланные'), findsOneWidget);
    expect(find.byKey(const Key('ord_new')), findsOneWidget);
    expect(find.text('Ознакомиться до 01.01'), findsOneWidget);
  });
}
