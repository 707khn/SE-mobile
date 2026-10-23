import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se_mobile/requests/business_trip_request.dart';
import 'package:se_mobile/screens/business_trip_detail_screen.dart';
import 'package:se_mobile/screens/business_trips_screen.dart';
import 'package:se_mobile/utils/lang.dart';
import 'package:se_mobile/utils/localization.dart';

import 'support/fake_server.dart';

/// Командировка: заявка, согласование, авансовый отчёт с остатком.
void main() {
  Map<String, dynamic> trip(int id, String status,
          {Map<String, bool> can = const {},
          bool mine = true,
          int? issued,
          List<Map<String, dynamic>> expenses = const [],
          int spent = 0,
          int balance = 0}) =>
      {
        'id': id,
        'destination': 'Астана',
        'organization': 'Заказчик',
        'purpose': 'Сдача документации',
        'date_from': '2030-01-20',
        'date_to': '2030-01-22',
        'days': 3,
        'transport': 'train',
        'advance_requested': 150000,
        'advance_issued': issued,
        'status': status,
        'note': '',
        'employee': {'id': '0000001674', 'name': 'Технолог Тест'},
        'expenses': expenses,
        'spent': spent,
        'balance': balance,
        'events': [],
        'is_mine': mine,
        for (final e in can.entries) 'can_${e.key}': e.value,
      };

  test('разбор и суммы', () {
    final t = BusinessTrip.fromJson(trip(1, 'advanced', issued: 150000));
    expect(t.days, 3);
    expect(businessTripDates(t), '20.01–22.01.2030');
    expect(tenge(150000), '150 000 ₸');
    expect(tenge(999), '999 ₸');
    expect(tenge(-1500), '−1 500 ₸');
    expect(BusinessTripList.fromJson({'daily_allowance': 7000}).dailyAllowance,
        7000);
  });

  test('надписи в обоих языках', () {
    final keys = LocaleString().keys;
    final ru = keys[Lang.ru]!.keys.where((k) => k.startsWith('bt_')).toSet();
    final kk = keys[Lang.kk]!.keys.where((k) => k.startsWith('bt_')).toSet();
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

  testWidgets('заявка уходит со сроками, транспортом и авансом',
      (tester) async {
    final server = FakeServer.routed((method, url, body) =>
        (201, jsonEncode({'message': 'Success', 'item': trip(3, 'pending')})));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, BusinessTripFormScreen(now: DateTime(2030, 1, 19)));
      expect(find.text('20.01.2030 – 22.01.2030 · 3 дн.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bt_send')));
      await tester.pump();
      expect(find.text('Укажите, куда'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('bt_destination')), 'Астана');
      await tester.enterText(
          find.byKey(const Key('bt_purpose')), 'Сдача документации');
      await tester.tap(find.byKey(const Key('bt_transport_plane')));
      await tester.enterText(find.byKey(const Key('bt_advance')), '150000');
      await tester.tap(find.byKey(const Key('bt_send')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.last), {
      'destination': 'Астана',
      'purpose': 'Сдача документации',
      'date_from': '2030-01-20',
      'date_to': '2030-01-22',
      'transport': 'plane',
      'advance': '150000',
    });
  });

  testWidgets('суточные подсказываются по числу дней', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': trip(5, 'advanced',
                  can: {'edit_report': true},
                  issued: 150000,
                  expenses: [
                    {'id': 1, 'category': 'per_diem', 'amount': 21000}
                  ],
                  spent: 21000,
                  balance: 129000)
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item': trip(5, 'advanced',
                  can: {'edit_report': true}, issued: 150000)
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester,
          const BusinessTripDetailScreen(tripId: 5, dailyAllowance: 7000));
      expect(find.text('Расходов пока нет'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bt_expense_add')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bt_category_per_diem')));
      await tester.pumpAndSettle();
      expect(find.text('21000'), findsOneWidget);
      await tester.tap(find.byKey(const Key('fields_ok')));
      await settle(tester);
      await tester.pumpAndSettle();
    }, server);
    expect(jsonDecode(server.requests.last), {
      'action': 'expense_add',
      'category': 'per_diem',
      'amount': '21000',
      'document': '',
    });
    expect(tester.widget<Text>(find.byKey(const Key('bt_balance'))).data,
        'Вернуть в кассу: 129 000 ₸');
  });

  testWidgets('руководитель согласует', (tester) async {
    final server = FakeServer.routed((method, url, body) => method == 'POST'
        ? (
            200,
            jsonEncode({
              'message': 'Success',
              'item': trip(6, 'approved', mine: false)
            })
          )
        : (
            200,
            jsonEncode({
              'message': 'Success',
              'item': trip(6, 'pending', mine: false, can: {'approve': true})
            })
          ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const BusinessTripDetailScreen(tripId: 6));
      expect(find.textContaining('Технолог Тест'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bt_approve')));
      await settle(tester);
    }, server);
    expect(jsonDecode(server.requests.last), {'action': 'approve'});
    expect(find.text('Согласована'), findsOneWidget);
  });

  testWidgets('у бухгалтерии — своя вкладка', (tester) async {
    final server = FakeServer.routed((method, url, body) => (
          200,
          jsonEncode({
            'message': 'Success',
            'accountant': true,
            'items': url.query.contains('accounting')
                ? [trip(7, 'reported', mine: false)]
                : [],
          })
        ));
    await HttpOverrides.runWithHttpOverrides(() async {
      await pump(tester, const BusinessTripsScreen());
    }, server);
    expect(find.text('Бухгалтерия (1)'), findsOneWidget);
    expect(find.text('Технолог Т. · Астана'), findsOneWidget);
    expect(find.text('Отчёт на проверке'), findsOneWidget);
  });
}
