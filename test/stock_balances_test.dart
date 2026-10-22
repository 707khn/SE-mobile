import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/stock_balance_request.dart';
import 'package:se_mobile/requests/stock_request.dart';
import 'package:se_mobile/screens/stock_balances_screen.dart';
import 'package:se_mobile/screens/stock_requests_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Остатки на складах: поиск, склады, предупреждение об устаревших.
void main() {
  Map<String, dynamic> answer(
          {List<Map<String, dynamic>> items = const [], bool stale = false}) =>
      {
        'message': 'Success',
        'as_of': '2030-01-15T03:00:00Z',
        'stale': stale,
        'warehouses': [
          {'name': 'Склад №1', 'as_of': '2030-01-15T03:00:00Z'},
          {'name': 'Склад №2', 'as_of': '2030-01-15T03:00:00Z'},
        ],
        'items': items,
        'more': false,
      };

  final electrodes = {
    'code': '00-123',
    'name': 'Электроды МР-3 ф3',
    'unit': 'кг',
    'total': 85.5,
    'warehouses': [
      {'name': 'Склад №1', 'quantity': 55},
      {'name': 'Склад №2', 'quantity': 30.5},
    ],
  };

  test('разбор и количество', () {
    final found = StockBalanceSearch.fromJson(answer(items: [electrodes, {}]));
    expect(found.items.single.places.length, 2);
    expect(found.items.single.total, 85.5);
    expect(found.warehouses, ['Склад №1', 'Склад №2']);
    expect(stockQuantity(5), '5');
    expect(stockQuantity(30.5), '30,5');
    expect(stockQuantity(0.125), '0,125');
    expect(StockRequestList.fromJson({'balances': true}).balances, isTrue);
    expect(StockRequestList.fromJson({}).balances, isFalse);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('sb_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('sb_')).toSet();
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

  testWidgets('мастер находит электроды на двух складах', (tester) async {
    final queries = <String?>[];
    final server = FakeServer.routed((method, url, body) {
      queries.add(url.queryParameters['q']);
      return (
        200,
        jsonEncode(url.queryParameters['q'] == null
            ? answer()
            : answer(items: [electrodes]))
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const StockBalancesScreen());
      expect(
          find.text(
              'Напишите, что ищете, — покажем, сколько и на каком складе.'),
          findsOneWidget);
      expect(find.byKey(const Key('sb_stale')), findsNothing);
      await tester.enterText(find.byKey(const Key('sb_search')), 'электрод мр');
      await tester.tap(find.byKey(const Key('sb_search_go')));
      await settle(tester);
    }, server);
    expect(queries, [null, 'электрод мр']);
    expect(find.text('Электроды МР-3 ф3'), findsOneWidget);
    expect(find.text('Всего: 85,5 кг'), findsOneWidget);
    expect(find.text('Склад №1'), findsOneWidget);
    expect(find.text('30,5 кг'), findsOneWidget);
  });

  testWidgets('предупреждает, что остатки устарели, и что не нашлось',
      (tester) async {
    final server = FakeServer.routed(
        (method, url, body) => (200, jsonEncode(answer(stale: true))));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const StockBalancesScreen());
      expect(find.byKey(const Key('sb_stale')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('sb_search')), 'фреза');
      await tester.tap(find.byKey(const Key('sb_search_go')));
      await settle(tester);
    }, server);
    expect(find.text('На складах не найдено'), findsOneWidget);
  });

  testWidgets('кнопка остатков — только тем, кому можно', (tester) async {
    for (final allowed in [true, false]) {
      final server = FakeServer.routed((method, url, body) => (
            200,
            jsonEncode({
              'message': 'Success',
              'staff': false,
              'balances': allowed,
              'items': []
            })
          ));
      await HttpOverrides.runWithHttpOverrides(() async {
        await pump(tester, StockRequestsScreen(key: ValueKey(allowed)));
      }, server);
      expect(find.byKey(const Key('stock_balances')),
          allowed ? findsOneWidget : findsNothing);
    }
  });
}
