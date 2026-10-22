import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/inventory_request.dart';
import 'package:se_mobile/screens/inventory_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Инвентаризация: код со сканера или снимка, привязка штрихкода, Excel.
void main() {
  Map<String, dynamic> line(int id, String code, String name,
          {double expected = 10, double? counted, double? diff}) =>
      {
        'id': id,
        'code': code,
        'name': name,
        'unit': 'кг',
        'expected': expected,
        'counted': counted,
        'extra': false,
        'diff': diff,
      };

  Map<String, dynamic> count({String status = 'open', int counted = 1}) => {
        'id': 5,
        'warehouse': 'Склад №1',
        'status': status,
        'as_of': '2030-01-14T06:00:00Z',
        'started_at': '2030-01-15T04:00:00Z',
        'started_by': {'id': '0000000009', 'name': 'Складова Анна'},
        'lines': 3,
        'counted': counted,
        'differences': 1,
      };

  final sheetJson = {
    'message': 'Success',
    'count': count(),
    'lines': [
      line(1, '00-300', 'Ветошь', counted: 10, diff: 0),
      line(2, '00-200', 'Перчатки х/б', expected: 85),
      line(3, '00-123', 'Электроды МР-3 ф3',
          expected: 55, counted: 50, diff: -5),
    ],
  };

  test('разбор пересчёта', () {
    final sheet = InventorySheet.fromJson(sheetJson);
    expect(sheet.count.open, isTrue);
    expect(sheet.count.startedBy?.name, 'Складова Анна');
    expect(sheet.lines[1].counted, isNull);
    expect(sheet.lines[2].diff, -5);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('inv_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('inv_')).toSet();
    expect(kk, ru);
  });

  test('в Excel — только расхождения', () {
    Get.locale = const Locale('ru');
    Get.addTranslations(LocaleString().keys);
    final bytes = buildInventoryExcel(InventorySheet.fromJson(sheetJson))!;
    final book = Excel.decodeBytes(bytes);
    final rows = book.tables[book.tables.keys.single]!.rows;
    String cell(int r, int c) => '${rows[r][c]?.value ?? ''}';
    expect(rows.length, 3);
    expect(cell(1, 5), 'Разница');
    expect([for (var c = 0; c < 6; c++) cell(2, c)],
        ['00-123', 'Электроды МР-3 ф3', 'кг', '55', '50', '-5']);

    final even = Map<String, dynamic>.from(sheetJson)
      ..['lines'] = [line(1, '00-300', 'Ветошь', counted: 10, diff: 0)];
    expect(buildInventoryExcel(InventorySheet.fromJson(even)), isNull);
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

  FakeServer countServer() => FakeServer.routed((method, url, body) {
        if (url.path.endsWith('/scan')) {
          final sent = jsonDecode(body) as Map<String, dynamic>;
          if (sent['line_id'] == null && sent['barcode'] == '4601234567893') {
            return (
              404,
              jsonEncode({
                'message': 'Failure',
                'error': 'unknown_code',
                'barcode': '4601234567893'
              })
            );
          }
          final id = sent['line_id'] ?? (sent['barcode'] == '00-123' ? 3 : 2);
          return (
            200,
            jsonEncode({
              'message': 'Success',
              'line': id == 3
                  ? line(3, '00-123', 'Электроды МР-3 ф3',
                      expected: 55, counted: 50, diff: -5)
                  : line(2, '00-200', 'Перчатки х/б',
                      expected: 85, counted: 40, diff: -45),
            })
          );
        }
        return (200, jsonEncode(sheetJson));
      });

  testWidgets('незнакомый штрихкод привязывают к позиции', (tester) async {
    final server = countServer();
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const InventoryCountScreen(countId: 5));
      expect(
          find.textContaining('Посчитано 1 из 3, расхождений: 1\n'
              'Остатки 1С на 14.01.2030'),
          findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('inv_code')), '4601234567893');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      expect(find.text('Код 4601234567893 не найден'), findsOneWidget);
      await tester.tap(find.byKey(const Key('inv_unknown_bind')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('inv_pick_search')), 'перч');
      await tester.pump();
      expect(find.byKey(const Key('inv_pick_3')), findsNothing);
      await tester.tap(find.byKey(const Key('inv_pick_2')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('inv_qty')), '40');
      await tester.pump();
      expect(find.byKey(const Key('inv_qty_set')), findsNothing);
      await tester.tap(find.byKey(const Key('inv_qty_add')));
      await settle(tester);
    }, server);
    expect(
        server.requests
            .where((r) => r.isNotEmpty)
            .map((r) => jsonDecode(r))
            .toList(),
        [
          {'barcode': '4601234567893'},
          {'barcode': '4601234567893', 'line_id': 2, 'quantity': '40'},
        ]);
    expect(find.text('Записано: Перчатки х/б — 40 кг'), findsOneWidget);
  });

  testWidgets('штрихкод со снимка, пересчёт вместо прежнего', (tester) async {
    final server = countServer();
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester,
          InventoryCountScreen(countId: 5, photo: () async => '00-123'));
      await tester.tap(find.byKey(const Key('inv_camera')));
      await settle(tester);
      expect(find.text('Уже посчитано: 50 кг'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('inv_qty')), '55');
      await tester.pump();
      await tester.tap(find.byKey(const Key('inv_qty_set')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)),
        {'line_id': 3, 'quantity': '55', 'mode': 'set'});
  });

  testWidgets('снимок без кода — подсказка', (tester) async {
    final server = countServer();
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(
          tester, InventoryCountScreen(countId: 5, photo: () async => null));
      await tester.tap(find.byKey(const Key('inv_camera')));
      await settle(tester);
    }, server);
    expect(find.textContaining('Код на снимке не нашёлся'), findsOneWidget);
    expect(server.requests.where((r) => r.isNotEmpty), isEmpty);
  });

  testWidgets('фильтр расхождений и итог', (tester) async {
    final server = countServer();
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const InventoryCountScreen(countId: 5));
      await tester.tap(find.byKey(const Key('inv_filter_diff')));
      await tester.pump();
      expect(find.byKey(const Key('inv_line_3')), findsOneWidget);
      expect(find.byKey(const Key('inv_line_1')), findsNothing);
      expect(find.text('−5'), findsOneWidget);
      await tester.tap(find.byKey(const Key('inv_filter_left')));
      await tester.pump();
      expect(find.byKey(const Key('inv_line_2')), findsOneWidget);
      expect(find.byKey(const Key('inv_line_3')), findsNothing);

      await tester.tap(find.byKey(const Key('inv_menu')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('inv_menu_remove')), findsNothing);
      await tester.tap(find.byKey(const Key('inv_menu_close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('inv_close_ok')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)),
        {'action': 'close'});
  });

  testWidgets('склад, где пересчёт уже идёт, открывает его', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        return (
          409,
          jsonEncode({'message': 'Failure', 'error': 'exists', 'id': 5})
        );
      }
      if (url.path.endsWith('/5')) return (200, jsonEncode(sheetJson));
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'warehouses': [
            {'name': 'Склад №1', 'items': 3, 'as_of': '2030-01-14T06:00:00Z'},
            {'name': 'Склад №2', 'items': 1, 'as_of': '2030-01-14T06:00:00Z'},
          ],
          'counts': [count()],
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const InventoryScreen());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('inv_count_5')), findsOneWidget);
      await tester.tap(find.byKey(const Key('inv_start')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('inv_warehouse_0')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.lastWhere((r) => r.isNotEmpty)),
        {'warehouse': 'Склад №1'});
    expect(find.byType(InventoryCountScreen), findsOneWidget);
    expect(find.text('На этом складе пересчёт уже идёт — открываю его.'),
        findsOneWidget);
  });
}
