import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/purchase_request.dart';
import 'package:se_mobile/screens/purchase_detail_screen.dart';
import 'package:se_mobile/screens/purchase_form_screen.dart';
import 'package:se_mobile/screens/purchases_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// «Где моя закупка»: этапы, очередь ДМТО, форма, перевод этапа.
void main() {
  const manager = '0000000110';

  Map<String, dynamic> item(int id, String status,
          {bool canAct = false,
          String? assignee,
          List<Map<String, dynamic>> events = const []}) =>
      {
        'id': id,
        'purpose': 'Ремонт пресса',
        'status': status,
        'needed_by': '2026-11-15',
        'urgent': false,
        'author': {'id': '0000001295', 'name': 'Инициатор Тест'},
        'assignee':
            assignee == null ? null : {'id': assignee, 'name': 'Менеджер Тест'},
        'supplier': '',
        'eta': null,
        'reason': '',
        'stale': false,
        'created_at': '2026-10-20T05:00:00+00:00',
        'lines': [
          {'name': 'Подшипник 6205', 'quantity': 4, 'unit': 'шт'}
        ],
        'events': events,
        'is_author': false,
        'can_act': canAct,
        'can_assign': false,
      };

  test('этапы и куда дальше', () {
    final p = Purchase.fromJson(item(1, 'accepted'));
    expect(p.stageIndex, 1);
    expect(p.nextStages, ['sourcing', 'contract', 'in_transit', 'delivered']);
    expect(Purchase.fromJson(item(2, 'new')).nextStages.first, 'sourcing');
    expect(Purchase.fromJson(item(3, 'delivered')).nextStages, isEmpty);
    expect(Purchase.fromJson(item(4, 'rejected')).stageIndex, -1);
    expect(Purchase.fromJson(item(5, 'contract')).neededBy,
        DateTime(2026, 11, 15));
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('purch_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('purch_')).toSet();
    expect(kk, ru);
    for (final s in [...purchaseStages, 'rejected', 'cancelled']) {
      expect(ru, contains('purch_stage_$s'));
    }
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, Widget home, {String? me}) async {
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(
        {if (me != null) 'employeeId': me});
    await tester.pumpWidget(GetMaterialApp(
      translations: LocaleString(),
      locale: const Locale('ru'),
      home: home,
    ));
    await settle(tester);
  }

  testWidgets('ДМТО: очередь со счётчиками и «На мне»', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.query == 'scope=queue') {
        return (
          200,
          jsonEncode({
            'staff': true,
            'open': {'new': 1, 'accepted': 1, 'sourcing': 1, 'in_transit': 2},
            'mine_open': 1,
            'items': [
              {...item(5, 'new'), 'purpose': 'Ничья'},
              {...item(6, 'sourcing', assignee: manager), 'purpose': 'Моя'},
            ],
          })
        );
      }
      return (200, jsonEncode({'staff': true, 'items': []}));
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const PurchasesScreen(), me: manager);
    }, server);
    expect(find.text('Новых: 1 · В работе: 2 · В пути: 2'), findsOneWidget);
    expect(find.text('Очередь (1)'), findsOneWidget);
    await tester.tap(find.text('На мне (1)'));
    await tester.pumpAndSettle();
    expect(find.text('№6 · Моя'), findsOneWidget);
    expect(find.text('№5 · Ничья'), findsNothing);
  });

  testWidgets('форма: срочно и позиции', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          201,
          jsonEncode({'message': 'Success', 'item': item(9, 'new')})
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const PurchaseFormScreen());
      await tester.tap(find.byKey(const Key('purch_send')));
      await tester.pump();
      expect(find.text('Напишите, для чего'), findsOneWidget);
      await tester.enterText(
          find.byKey(const Key('purch_purpose')), 'Ремонт пресса');
      await tester.enterText(
          find.byKey(const Key('purch_line_name_0')), 'Подшипник 6205');
      await tester.enterText(find.byKey(const Key('purch_line_qty_0')), '4');
      await tester.tap(find.byKey(const Key('purch_urgent')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('purch_send')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.single) as Map<String, dynamic>;
    expect(sent, {
      'purpose': 'Ремонт пресса',
      'urgent': true,
      'lines': [
        {'name': 'Подшипник 6205', 'quantity': 4.0, 'unit': 'шт'}
      ],
    });
  });

  testWidgets('менеджер переводит «в договор» с поставщиком', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        return (
          200,
          jsonEncode({
            'message': 'Success',
            'item': {
              ...item(4, 'contract', canAct: true, assignee: manager, events: [
                {'action': 'created', 'stage': 'new', 'at': '2026-10-20T05:00:00Z'},
                {'action': 'take', 'stage': 'accepted', 'at': '2026-10-21T05:00:00Z'},
                {'action': 'stage', 'stage': 'contract', 'at': '2026-10-22T05:00:00Z'},
              ]),
              'supplier': 'ТОО «Подшипник»'
            }
          })
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'item': item(4, 'accepted', canAct: true, assignee: manager)
        })
      );
    });
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const PurchaseDetailScreen(purchaseId: 4),
          me: manager);
      // Уже на мне — «Взять себе» не нужно.
      expect(find.byKey(const Key('purch_take')), findsNothing);
      await tester.tap(find.byKey(const Key('purch_next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('purch_to_contract')));
      await tester.pump();
      await tester.enterText(
          find.byKey(const Key('purch_supplier')), 'ТОО «Подшипник»');
      await tester.tap(find.byKey(const Key('purch_stage_ok')));
      await settle(tester);
    }, server);
    await tester.pumpAndSettle();
    final sent = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(sent, {
      'action': 'stage',
      'stage': 'contract',
      'supplier': 'ТОО «Подшипник»'
    });
    expect(find.text('Поставщик: ТОО «Подшипник»'), findsOneWidget);
    // Чип, строка этапа и запись в истории.
    expect(find.text('Договор на согласовании'), findsNWidgets(3));
  });
}
