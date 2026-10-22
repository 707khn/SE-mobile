import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/lunch_order_request.dart';
import 'package:se_mobile/screens/lunch_order_screen.dart';
import 'package:se_mobile/screens/lunch_summary_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Предзаказ обеда: выбор блюд, сумма, итог для столовой.
void main() {
  final menu = [
    {'id': 11, 'category': 'Первое', 'name': 'Борщ', 'price': 800},
    {'id': 12, 'category': 'Второе', 'name': 'Плов', 'price': 1500},
  ];

  Map<String, dynamic> day(
          {bool open = true,
          bool canteen = false,
          Map<String, dynamic>? order}) =>
      {
        'message': 'Success',
        'date': '2030-01-15',
        'open': open,
        'cutoff': '10:30',
        'canteen': canteen,
        'menu': menu,
        'order': order,
        'upcoming': [],
      };

  Map<String, dynamic> order(int id,
          {bool served = false, String name = 'Технолог Тест'}) =>
      {
        'id': id,
        'date': '2030-01-15',
        'note': '',
        'served': served,
        'lines': [
          {'category': 'Второе', 'name': 'Плов', 'price': 1500, 'quantity': 2}
        ],
        'total': 3000,
        'employee': {'id': '0000001674', 'name': name, 'department': 'ОГТ'},
      };

  test('разбор дня и заказа', () {
    final d = LunchDay.fromJson(day(order: order(3)));
    expect(d.open, isTrue);
    expect(d.menu.map((m) => m.name), ['Борщ', 'Плов']);
    expect(d.order!.lines.single.quantity, 2);
    expect(d.order!.total, 3000);
    expect(lunchDay(DateTime(2030, 1, 5)), '2030-01-05');
    final s = LunchSummary.fromJson({
      'count': 1,
      'served': 0,
      'dishes': [
        {'category': 'Второе', 'name': 'Плов', 'quantity': 2}
      ],
      'orders': [order(3)],
    });
    expect(s.dishes.single.quantity, 2);
    expect(s.orders.single.employeeName, 'Технолог Тест');
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('lo_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('lo_')).toSet();
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

  String text(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

  testWidgets('выбор блюд, сумма и заказ', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'PUT'
        ? (201, jsonEncode({'message': 'Success', 'order': order(5)}))
        : (200, jsonEncode(day())));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, LunchOrderScreen(day: DateTime(2030, 1, 15)));
      expect(text(tester, 'lo_state'),
          'Заказ можно сделать или поправить до 10:30 в день обеда');
      expect(find.byKey(const Key('lo_cancel')), findsNothing);
      expect(find.byKey(const Key('lo_summary')), findsNothing);
      for (final key in ['lo_plus_12', 'lo_plus_12', 'lo_plus_11']) {
        await tester.tap(find.byKey(Key(key)));
        await tester.pump();
      }
      await tester.tap(find.byKey(const Key('lo_minus_11')));
      await tester.pump();
      expect(text(tester, 'lo_count_12'), '2');
      expect(text(tester, 'lo_count_11'), '0');
      expect(text(tester, 'lo_total'), 'По ценам меню: 3 000 ₸');
      await tester.enterText(find.byKey(const Key('lo_note')), 'без лука');
      await tester.pump();
      await tester.tap(find.byKey(const Key('lo_save')));
      await settle(tester);
    }, server);
    final put = server.requests.firstWhere((r) => r.isNotEmpty);
    expect(jsonDecode(put), {
      'date': '2030-01-15',
      'items': [
        {'menu_item_id': 12, 'quantity': 2}
      ],
      'note': 'без лука',
    });
  });

  testWidgets('прежний заказ подставляется, после отсечки — только просмотр',
      (tester) async {
    final server = FakeServer.routed((method, url, body) =>
        (200, jsonEncode(day(open: false, order: order(5)))));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, LunchOrderScreen(day: DateTime(2030, 1, 15)));
    }, server);
    expect(text(tester, 'lo_state'), 'Заказ на этот день уже не принимается');
    expect(text(tester, 'lo_count_12'), '2');
    expect(find.byKey(const Key('lo_plus_12')), findsNothing);
    expect(find.byKey(const Key('lo_save')), findsNothing);
  });

  testWidgets('столовая видит итог и отмечает выдачу', (tester) async {
    var served = false;
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        served = jsonDecode(body)['served'] == true;
        return (
          200,
          jsonEncode({'message': 'Success', 'order': order(5, served: served)})
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'count': 1,
          'served': served ? 1 : 0,
          'dishes': [
            {'category': 'Второе', 'name': 'Плов', 'quantity': 2}
          ],
          'orders': [order(5, served: served)],
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, LunchSummaryScreen(day: DateTime(2030, 1, 15)));
      expect(text(tester, 'lo_counts'), 'Заказов: 1 · выдано: 0');
      expect(find.text('× 2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('lo_served_5')));
      await settle(tester);
    }, server);
    expect(server.requests.where((r) => r.isNotEmpty).single,
        jsonEncode({'served': true}));
    expect(text(tester, 'lo_counts'), 'Заказов: 1 · выдано: 1');
  });
}
