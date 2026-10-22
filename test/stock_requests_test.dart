import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/stock_request.dart';
import 'package:se_mobile/screens/stock_request_detail_screen.dart';
import 'package:se_mobile/screens/stock_request_form_screen.dart';
import 'package:se_mobile/screens/stock_requests_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Заявки на ТМЦ: разбор, форма с позициями, «Собрано» с отметкой «нет».
void main() {
  Map<String, dynamic> item(int id, String status,
          {int? warehouse = 1, bool canAct = false}) =>
      {
        'id': id,
        'warehouse': warehouse,
        'purpose': 'Участок 3',
        'status': status,
        'author': {'id': '0000002107', 'name': 'Автор Тест'},
        'assignee': null,
        'resolution': '',
        'created_at': '2026-10-22T05:00:00+00:00',
        'lines': [
          {'id': 11, 'name': 'Электроды', 'quantity': 5, 'unit': 'кг', 'missing': false},
          {'id': 12, 'name': 'Круг', 'quantity': 2.5, 'unit': 'шт', 'missing': true},
        ],
        'events': [],
        'can_act': canAct,
      };

  test('разбор и количество по-русски', () {
    final r = StockRequest.fromJson(item(3, 'ready'));
    expect(r.lines.first.amount, '5 кг');
    expect(r.lines.last.amount, '2,5 шт');
    expect(r.missingCount, 1);
    expect(r.isOpen, isTrue);
    final list = StockRequestList.fromJson(
        {'staff': true, 'my_warehouse': 2, 'items': [item(1, 'new'), 7]});
    expect(list.items.single.id, 1);
    expect(list.myWarehouse, 2);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('stock_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('stock_')).toSet();
    expect(kk, ru);
    for (final s in ['new', 'in_progress', 'ready', 'issued', 'rejected', 'cancelled']) {
      expect(ru, contains('stock_status_$s'));
    }
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, FakeServer server, Widget home) async {
    tester.view.physicalSize = const Size(900, 1800);
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

  testWidgets('кладовщик: свой склад в очереди наверху', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.query == 'scope=queue') {
        return (
          200,
          jsonEncode({
            'staff': true,
            'my_warehouse': 2,
            'open': {'new': 2, 'in_progress': 0, 'ready': 0},
            'items': [
              {...item(5, 'new', warehouse: 1), 'purpose': 'Первый'},
              {...item(6, 'new', warehouse: 2), 'purpose': 'Второй'},
            ],
          })
        );
      }
      return (200, jsonEncode({'staff': true, 'items': []}));
    });
    await pump(tester, server, const StockRequestsScreen());
    expect(find.text('Новых: 2 · Собирают: 0 · Готово: 0'), findsOneWidget);
    final second = tester.getTopLeft(find.text('№6 · Второй')).dy;
    final first = tester.getTopLeft(find.text('№5 · Первый')).dy;
    expect(second, lessThan(first));
  });

  testWidgets('форма: пустая строка не мешает, без названия — не уходит',
      (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          201,
          jsonEncode({'message': 'Success', 'item': item(9, 'new')})
        ));
    await pump(tester, server, const StockRequestFormScreen());
    await tester.enterText(find.byKey(const Key('stock_purpose')), 'Участок 3');
    await tester.enterText(find.byKey(const Key('stock_line_qty_0')), '5');
    await tester.tap(find.byKey(const Key('stock_send')));
    await tester.pump();
    expect(find.text('Напишите наименование позиции'), findsOneWidget);

    await tester.enterText(
        find.byKey(const Key('stock_line_name_0')), 'Электроды');
    await tester.enterText(find.byKey(const Key('stock_line_qty_0')), '2,5');
    await tester.tap(find.byKey(const Key('stock_add_line')));
    await tester.pump();
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.byKey(const Key('stock_send')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.single) as Map<String, dynamic>;
    expect(sent['purpose'], 'Участок 3');
    expect(sent['warehouse'], isNull);
    expect(sent['lines'], [
      {'name': 'Электроды', 'quantity': 2.5, 'unit': 'шт'}
    ]);
  });

  testWidgets('«Собрано» уходит с отмеченными «нет»', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        return (200, jsonEncode({'message': 'Success', 'item': item(4, 'ready', canAct: true)}));
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'item': {
            ...item(4, 'in_progress', canAct: true),
            'lines': [
              {'id': 11, 'name': 'Электроды', 'quantity': 5, 'unit': 'кг'},
              {'id': 12, 'name': 'Круг', 'quantity': 2, 'unit': 'шт'},
            ],
          }
        })
      );
    });
    await pump(tester, server, const StockRequestDetailScreen(requestId: 4));
    expect(find.text('Отметьте, чего нет'), findsOneWidget);
    await tester.tap(find.byKey(const Key('stock_line_12')));
    await tester.pump();
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.byKey(const Key('stock_ready')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(sent['action'], 'ready');
    expect(sent['missing'], [12]);
    expect(find.text('Готово'), findsOneWidget);
  });
}
