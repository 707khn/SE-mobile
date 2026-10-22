import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/inspection_request.dart';
import 'package:se_mobile/screens/inspection_detail_screen.dart';
import 'package:se_mobile/screens/inspection_form_screen.dart';
import 'package:se_mobile/screens/inspections_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Предъявление продукции: разбор, очередь ОТК, форма, возврат и повтор.
void main() {
  const author = '0000002107';

  Map<String, dynamic> item(int id, String status,
          {bool canAct = false, List<Map<String, dynamic>> events = const []}) =>
      {
        'id': id,
        'product': 'Корпус 7.01',
        'quantity': 12,
        'order_no': 'Заказ 112',
        'place': 'Участок 3',
        'note': '',
        'needs_vp': true,
        'status': status,
        'stage': status.endsWith('_otk')
            ? 'otk'
            : status.endsWith('_vp')
                ? 'vp'
                : null,
        'author': {'id': author, 'name': 'Мастер Тест'},
        'otk': null,
        'vp': null,
        'return_reason': status == 'returned' ? 'Заусенцы на кромке' : '',
        'returns': status == 'returned' ? 1 : 0,
        'stage_since': DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 3))
            .toIso8601String(),
        'created_at': '2026-10-22T05:00:00+00:00',
        'events': events,
        'can_act': canAct,
      };

  test('разбор и сколько ждёт', () {
    final i = Inspection.fromJson(item(3, 'waiting_otk'));
    expect(i.stage, 'otk');
    expect(i.needsVp, isTrue);
    expect(i.inFlight, isTrue);
    expect(i.waitingHours(DateTime.now())!.round(), 3);
    final done = Inspection.fromJson(item(4, 'accepted'));
    expect(done.stage, isNull);
    expect(done.waitingHours(DateTime.now()), isNull);
    expect(done.isOpen, isFalse);
    final list = InspectionList.fromJson({
      'staff': true,
      'roles': {'otk': true, 'vp': false, 'watch': false},
      'open': {'waiting_otk': 2, 'checking_otk': 1, 'waiting_vp': 1},
      'items': [item(1, 'waiting_otk'), 7],
    });
    expect(list.items.single.id, 1);
    expect(list.otk, isTrue);
    expect(list.vp, isFalse);
    expect(list.open['checking_otk'], 1);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('insp_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('insp_')).toSet();
    expect(kk, ru);
    for (final s in [
      'waiting_otk',
      'checking_otk',
      'waiting_vp',
      'checking_vp',
      'accepted',
      'returned',
      'cancelled'
    ]) {
      expect(ru, contains('insp_status_$s'));
    }
    for (final a in ['take', 'accept', 'return']) {
      expect(ru, containsAll(['insp_ev_${a}_otk', 'insp_ev_${a}_vp']));
    }
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester, FakeServer server, Widget home,
      {String? me}) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(Lang.initDates);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues(
        {if (me != null) 'employeeId': me});
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.pumpWidget(GetMaterialApp(
        translations: LocaleString(),
        locale: const Locale('ru'),
        home: home,
      ));
      await settle(tester);
    }, server);
  }

  testWidgets('ОТК: очередь со счётчиками и временем ожидания',
      (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (url.query == 'scope=queue') {
        return (
          200,
          jsonEncode({
            'staff': true,
            'roles': {'otk': true, 'vp': false, 'watch': false},
            'open': {'waiting_otk': 2, 'checking_otk': 1, 'waiting_vp': 1},
            'items': [item(5, 'waiting_otk')],
          })
        );
      }
      return (
        200,
        jsonEncode({
          'staff': true,
          'roles': {'otk': true},
          'items': []
        })
      );
    });
    await pump(tester, server, const InspectionsScreen());
    expect(find.text('Ждёт ОТК: 3 · Ждёт ВП: 1'), findsOneWidget);
    expect(find.text('Очередь (2)'), findsOneWidget);
    expect(find.text('№5 · Корпус 7.01 — 12 шт'), findsOneWidget);
    expect(find.textContaining('ждёт 3 ч'), findsOneWidget);
  });

  testWidgets('форма: без количества не уходит, участок запоминается',
      (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          201,
          jsonEncode({'message': 'Success', 'item': item(9, 'waiting_otk')})
        ));
    await pump(tester, server, const InspectionFormScreen());
    await tester.enterText(find.byKey(const Key('insp_product')), 'Корпус');
    await tester.enterText(find.byKey(const Key('insp_place')), 'Участок 3');
    await tester.tap(find.byKey(const Key('insp_send')));
    await tester.pump();
    expect(find.text('Проверьте количество'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('insp_quantity')), '12');
    await tester.tap(find.byKey(const Key('insp_needs_vp')));
    await tester.pump();
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.byKey(const Key('insp_send')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.single) as Map<String, dynamic>;
    expect(sent, {
      'product': 'Корпус',
      'quantity': 12,
      'place': 'Участок 3',
      'needs_vp': true,
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('insp_last_place'), 'Участок 3');
    expect(prefs.getBool('insp_last_needs_vp'), isTrue);
  });

  testWidgets('ОТК возвращает только с причиной', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        return (
          200,
          jsonEncode({'message': 'Success', 'item': item(4, 'returned')})
        );
      }
      return (
        200,
        jsonEncode({
          'message': 'Success',
          'item': item(4, 'checking_otk', canAct: true, events: [
            {'action': 'created', 'stage': 'otk', 'at': '2026-10-22T05:00:00Z'},
            {'action': 'take', 'stage': 'otk', 'at': '2026-10-22T06:00:00Z'},
          ])
        })
      );
    });
    await pump(tester, server, const InspectionDetailScreen(inspectionId: 4),
        me: '0000000001');
    expect(find.text('ОТК взял на проверку'), findsOneWidget);
    // Уже взята — «Взять» не нужно, остаются «Принять» и «Вернуть».
    expect(find.byKey(const Key('insp_take')), findsNothing);
    expect(find.byKey(const Key('insp_resubmit')), findsNothing);

    // Запрос уходит из того же вызова, что открыл диалог, — оба под сервером.
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.byKey(const Key('insp_return')));
      await tester.pumpAndSettle();
      final ok = find.byKey(const Key('prompt_ok'));
      expect(tester.widget<TextButton>(ok).onPressed, isNull);
      await tester.enterText(
          find.byKey(const Key('prompt_text')), 'Заусенцы на кромке');
      await tester.pump();
      await tester.tap(ok);
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(sent, {'action': 'return', 'comment': 'Заусенцы на кромке'});
    expect(find.text('На доработке'), findsOneWidget);
    expect(find.text('Причина возврата: Заусенцы на кромке'), findsOneWidget);
  });

  testWidgets('автор после возврата предъявляет повторно', (tester) async {
    final server = FakeServer.routed((method, url, body) {
      if (method == 'POST') {
        return (
          200,
          jsonEncode({'message': 'Success', 'item': item(4, 'waiting_otk')})
        );
      }
      return (
        200,
        jsonEncode({'message': 'Success', 'item': item(4, 'returned')})
      );
    });
    await pump(tester, server, const InspectionDetailScreen(inspectionId: 4),
        me: author);
    expect(find.byKey(const Key('insp_accept')), findsNothing);
    await HttpOverrides.runWithHttpOverrides(() async {
      await tester.tap(find.byKey(const Key('insp_resubmit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('prompt_ok')));
      await settle(tester);
    }, server);
    final sent = jsonDecode(server.requests.last) as Map<String, dynamic>;
    expect(sent, {'action': 'resubmit'});
    expect(find.text('Ждёт ОТК'), findsOneWidget);
    expect(find.byKey(const Key('insp_resubmit')), findsNothing);
  });
}
